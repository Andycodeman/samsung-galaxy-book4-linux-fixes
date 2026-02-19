-- Disable raw V4L2 IPU7 ISYS capture nodes in PipeWire.
-- These are internal pipeline nodes from the IPU7 kernel driver that output
-- raw bayer data unusable by applications. libcamera handles the actual camera
-- pipeline and exposes a proper source — this rule only affects the V4L2 monitor.
-- WirePlumber 0.4 format (Ubuntu 24.04)

table.insert(v4l2_monitor.rules, {
  matches = {
    {
      { "api.v4l2.cap.card", "matches", "ipu7" },
    },
  },
  apply_properties = {
    ["device.disabled"] = true,
  },
})
