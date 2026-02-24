#!/usr/bin/env python3
"""Camera Relay systray indicator — thin wrapper around the camera-relay CLI."""

import json
import os
import subprocess
import sys
import threading

# Require a display server
if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
    print("camera-relay-systray: No display detected, exiting.", file=sys.stderr)
    sys.exit(0)

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

# Try AppIndicator3 (GNOME with extension, KDE, others)
USE_APPINDICATOR = False
try:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3
    USE_APPINDICATOR = True
except (ValueError, ImportError):
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3
        USE_APPINDICATOR = True
    except (ValueError, ImportError):
        pass

RELAY_CMD = "/usr/local/bin/camera-relay"
POLL_INTERVAL = 5  # seconds


class CameraRelaySystray:
    def __init__(self):
        self.running = False
        self.persistent = False

        if USE_APPINDICATOR:
            self.indicator = AppIndicator3.Indicator.new(
                "camera-relay",
                "camera-video-symbolic",
                AppIndicator3.IndicatorCategory.HARDWARE,
            )
            self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            self.indicator.set_menu(self._build_menu())
        else:
            print(
                "camera-relay-systray: AppIndicator3 not available. "
                "Install gnome-shell-extension-appindicator (GNOME) or "
                "libappindicator-gtk3 (KDE/other).",
                file=sys.stderr,
            )
            print(
                "camera-relay-systray: Falling back to Gtk.StatusIcon.",
                file=sys.stderr,
            )
            self.status_icon = Gtk.StatusIcon()
            self.status_icon.set_from_icon_name("camera-video-symbolic")
            self.status_icon.set_tooltip_text("Camera Relay")
            self.status_icon.connect("popup-menu", self._on_status_icon_popup)
            self.status_icon.set_visible(True)

        # Initial status check, then poll
        self._poll_status()
        GLib.timeout_add_seconds(POLL_INTERVAL, self._poll_status)

    def _build_menu(self):
        menu = Gtk.Menu()

        self.item_toggle = Gtk.MenuItem(label="Start Relay")
        self.item_toggle.connect("activate", self._on_toggle)
        menu.append(self.item_toggle)

        menu.append(Gtk.SeparatorMenuItem())

        self.item_persistent = Gtk.MenuItem(label="Enable Persistent Mode")
        self.item_persistent.connect("activate", self._on_persistent_toggle)
        menu.append(self.item_persistent)

        menu.append(Gtk.SeparatorMenuItem())

        self.item_status = Gtk.MenuItem(label="Status: checking...")
        self.item_status.set_sensitive(False)
        menu.append(self.item_status)

        menu.append(Gtk.SeparatorMenuItem())

        item_quit = Gtk.MenuItem(label="Quit")
        item_quit.connect("activate", self._on_quit)
        menu.append(item_quit)

        menu.show_all()
        return menu

    def _on_status_icon_popup(self, icon, button, time):
        menu = self._build_menu()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, time)

    def _get_status(self):
        try:
            result = subprocess.run(
                [RELAY_CMD, "status", "--json"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            return json.loads(result.stdout)
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            return {"running": False, "persistent": False, "camera": "", "device": ""}

    def _poll_status(self):
        status = self._get_status()
        self.running = status.get("running", False)
        self.persistent = status.get("persistent", False)

        # Update menu labels
        if hasattr(self, "item_toggle"):
            self.item_toggle.set_label(
                "Stop Relay" if self.running else "Start Relay"
            )
        if hasattr(self, "item_persistent"):
            self.item_persistent.set_label(
                "Disable Persistent Mode"
                if self.persistent
                else "Enable Persistent Mode"
            )
        if hasattr(self, "item_status"):
            state = "RUNNING" if self.running else "STOPPED"
            persist = " (persistent)" if self.persistent else ""
            self.item_status.set_label(f"Status: {state}{persist}")

        # Update icon
        icon = "camera-video-symbolic" if self.running else "camera-disabled-symbolic"
        if USE_APPINDICATOR:
            self.indicator.set_icon(icon)
        else:
            self.status_icon.set_from_icon_name(icon)

        return True  # keep polling

    def _on_toggle(self, _widget):
        action = "stop" if self.running else "start"
        # Disable toggle while action is in progress
        if hasattr(self, "item_toggle"):
            self.item_toggle.set_label("Stopping..." if self.running else "Starting...")
            self.item_toggle.set_sensitive(False)

        def _run_action():
            try:
                result = subprocess.run(
                    [RELAY_CMD, action],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if result.returncode != 0:
                    error = result.stderr.strip() or result.stdout.strip() or "Unknown error"
                    GLib.idle_add(self._show_error, f"Failed to {action} relay:\n\n{error}")
            except subprocess.TimeoutExpired:
                GLib.idle_add(self._show_error, f"Timed out trying to {action} relay")
            except Exception as e:
                GLib.idle_add(self._show_error, f"Error: {e}")
            # Update UI from main thread after action completes
            GLib.idle_add(self._poll_status_once)

        threading.Thread(target=_run_action, daemon=True).start()

    def _poll_status_once(self):
        """One-shot status update (for use with GLib.idle_add after actions)."""
        self._poll_status()
        # Re-enable toggle button
        if hasattr(self, "item_toggle"):
            self.item_toggle.set_sensitive(True)
        return False  # do NOT repeat

    def _show_error(self, message):
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text="Camera Relay Error",
        )
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()
        return False  # for GLib.idle_add

    def _on_persistent_toggle(self, _widget):
        if self.persistent:
            subprocess.Popen([RELAY_CMD, "disable-persistent"])
            GLib.timeout_add(1000, self._poll_status)
        else:
            self._show_persistent_warning()

    def _show_persistent_warning(self):
        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Enable Persistent Mode?",
        )
        dialog.format_secondary_text(
            "This will keep the camera relay running at all times after login.\n\n"
            "Battery impact: ~2-3% extra per charge cycle\n"
            "CPU usage: ~2-3% while active\n\n"
            "The relay will auto-start on every login and run continuously "
            "in the background. You can disable this later from this menu "
            "or by running:\n\n"
            "  camera-relay disable-persistent"
        )
        dialog.set_title("Camera Relay")

        response = dialog.run()
        dialog.destroy()

        if response == Gtk.ResponseType.OK:
            subprocess.Popen([RELAY_CMD, "enable-persistent", "--yes"])
            GLib.timeout_add(1000, self._poll_status)

    def _on_quit(self, _widget):
        Gtk.main_quit()


if __name__ == "__main__":
    app = CameraRelaySystray()
    Gtk.main()
