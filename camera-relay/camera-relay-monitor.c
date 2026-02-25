/*
 * camera-relay-monitor — Lightweight v4l2loopback client event monitor
 *
 * Opens the v4l2loopback device for writing and periodically writes
 * black frames to keep ready_for_capture=1 (required for capture
 * clients to STREAMON). Monitors for client connections and prints
 * "START" when a capture client connects, "STOP" when the last
 * client disconnects. The camera-relay bash script reads these
 * events to start/stop the real GStreamer camera pipeline.
 *
 * When the real pipeline starts, the monitor stops writing black
 * frames (pipeline's v4l2sink takes over writing real frames).
 *
 * Build:  gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
 * Usage:  camera-relay-monitor /dev/video0 [width height]
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Event IDs for v4l2loopback versions */
#define V4L2_EVENT_CLIENT_USAGE_OLD  (V4L2_EVENT_PRIVATE_START)
#define V4L2_EVENT_CLIENT_USAGE_NEW  (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

static volatile sig_atomic_t running = 1;
static __u32 event_type = 0;

static void handle_signal(int sig)
{
	(void)sig;
	running = 0;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

static int count_other_openers(dev_t dev_id, pid_t our_pid)
{
	DIR *proc_dir;
	struct dirent *proc_entry;
	int count = 0;

	proc_dir = opendir("/proc");
	if (!proc_dir)
		return 0;

	while ((proc_entry = readdir(proc_dir)) != NULL) {
		char *endp;
		long pid = strtol(proc_entry->d_name, &endp, 10);
		if (*endp != '\0' || pid <= 0)
			continue;
		if ((pid_t)pid == our_pid)
			continue;

		char fd_dir_path[128];
		snprintf(fd_dir_path, sizeof(fd_dir_path),
			 "/proc/%ld/fd", pid);

		DIR *fd_dir = opendir(fd_dir_path);
		if (!fd_dir)
			continue;

		struct dirent *fd_entry;
		int found = 0;
		while ((fd_entry = readdir(fd_dir)) != NULL) {
			char link_path[384];
			struct stat st;

			snprintf(link_path, sizeof(link_path),
				 "%s/%s", fd_dir_path, fd_entry->d_name);

			if (stat(link_path, &st) == 0 &&
			    S_ISCHR(st.st_mode) &&
			    st.st_rdev == dev_id) {
				found = 1;
				break;
			}
		}
		closedir(fd_dir);
		if (found)
			count++;
	}
	closedir(proc_dir);
	return count;
}

static int try_subscribe_events(int fd)
{
	struct v4l2_event_subscription sub;

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_OLD;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		event_type = V4L2_EVENT_CLIENT_USAGE_OLD;
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.12.x event API\n");
		return 1;
	}

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_NEW;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		event_type = V4L2_EVENT_CLIENT_USAGE_NEW;
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.13+ event API\n");
		return 1;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	const char *device;
	int width = 1920, height = 1080;
	int fd, use_events = 0;
	int frame_size;

	if (argc < 2 || argc > 4) {
		fprintf(stderr, "Usage: %s <device> [width height]\n",
			argv[0]);
		return 1;
	}

	device = argv[1];
	if (argc >= 3)
		width = atoi(argv[2]);
	if (argc >= 4)
		height = atoi(argv[3]);

	frame_size = width * height * 2;  /* YUY2: 2 bytes/pixel */

	setvbuf(stdout, NULL, _IOLBF, 0);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	fd = open(device, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "ERROR: Cannot open %s: %s\n",
			device, strerror(errno));
		return 1;
	}

	/* Allocate YUY2 black frame (BT.601: Y=0x10, U=V=0x80) */
	char *black_frame = malloc(frame_size);
	if (!black_frame) {
		fprintf(stderr, "ERROR: Cannot allocate frame buffer\n");
		close(fd);
		return 1;
	}
	for (int i = 0; i < frame_size; i += 4) {
		black_frame[i + 0] = 0x10;
		black_frame[i + 1] = 0x80;
		black_frame[i + 2] = 0x10;
		black_frame[i + 3] = 0x80;
	}

	/*
	 * Set the output format so v4l2loopback knows the frame size.
	 * This must happen before write() — without it, the device has
	 * buffer_size=0 and write() returns EINVAL.
	 */
	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = width;
	fmt.fmt.pix.height = height;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.sizeimage = frame_size;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;

	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
		fprintf(stderr, "WARNING: VIDIOC_S_FMT: %s\n",
			strerror(errno));
	}

	/*
	 * Write initial frame. On v4l2loopback 0.12.x, write() sets
	 * ready_for_capture=1 which allows capture clients to STREAMON.
	 * Without this, capture clients get EIO.
	 */
	if (write(fd, black_frame, frame_size) != frame_size) {
		fprintf(stderr, "WARNING: Initial frame write: %s\n",
			strerror(errno));
	}

	/* Subscribe to client events */
	use_events = try_subscribe_events(fd);
	if (!use_events) {
		fprintf(stderr,
			"[monitor] No event support, using /proc polling\n");
	}

	fprintf(stderr, "[monitor] Watching %s (%dx%d)\n",
		device, width, height);
	printf("READY\n");

	if (use_events) {
		struct pollfd pfd;
		pfd.fd = fd;
		pfd.events = POLLPRI;
		int pipeline_active = 0;

		/* Drain initial event */
		{
			struct v4l2_event ev;
			memset(&ev, 0, sizeof(ev));
			xioctl(fd, VIDIOC_DQEVENT, &ev);
		}

		while (running) {
			int ret = poll(&pfd, 1, 1000);
			if (ret < 0) {
				if (errno == EINTR)
					continue;
				fprintf(stderr, "ERROR: poll: %s\n",
					strerror(errno));
				break;
			}

			/*
			 * Write black frame when idle to keep
			 * ready_for_capture=1 for new clients.
			 */
			if (!pipeline_active)
				(void)!write(fd, black_frame, frame_size);

			if (ret == 0)
				continue;

			if (pfd.revents & POLLPRI) {
				struct v4l2_event ev;
				memset(&ev, 0, sizeof(ev));

				if (xioctl(fd, VIDIOC_DQEVENT, &ev) < 0)
					continue;

				if (ev.type == event_type) {
					__u32 count;
					memcpy(&count, &ev.u,
						sizeof(count));

					int clients_active;
					if (event_type ==
					    V4L2_EVENT_CLIENT_USAGE_OLD)
						clients_active =
							(count > 0);
					else
						clients_active =
							(count == 0);

					if (clients_active &&
					    !pipeline_active) {
						fprintf(stderr,
							"[monitor] Client"
							" connected"
							" (count=%u)\n",
							count);
						printf("START\n");
						pipeline_active = 1;
					} else if (!clients_active &&
						   pipeline_active) {
						fprintf(stderr,
							"[monitor] Client"
							" disconnected"
							" (count=%u)\n",
							count);
						printf("STOP\n");
						pipeline_active = 0;
					}
				}
			}
		}
	} else {
		/* Polling mode */
		struct stat dev_stat;
		if (stat(device, &dev_stat) < 0) {
			fprintf(stderr, "ERROR: Cannot stat %s: %s\n",
				device, strerror(errno));
			free(black_frame);
			close(fd);
			return 1;
		}

		pid_t our_pid = getpid();
		int prev_clients = 0;
		int pipeline_active = 0;

		while (running) {
			int clients = count_other_openers(
				dev_stat.st_rdev, our_pid);

			if (clients > 0 && prev_clients == 0) {
				fprintf(stderr,
					"[monitor] Client detected (%d)\n",
					clients);
				printf("START\n");
				pipeline_active = 1;
			} else if (clients == 0 && prev_clients > 0) {
				fprintf(stderr,
					"[monitor] All clients"
					" disconnected\n");
				printf("STOP\n");
				pipeline_active = 0;
			}
			prev_clients = clients;

			if (!pipeline_active)
				(void)!write(fd, black_frame, frame_size);

			for (int i = 0; i < 10 && running; i++)
				usleep(100000);
		}
	}

	fprintf(stderr, "[monitor] Shutting down\n");
	free(black_frame);
	close(fd);
	return 0;
}
