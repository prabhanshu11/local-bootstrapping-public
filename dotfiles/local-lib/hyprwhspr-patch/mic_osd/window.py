"""
GTK4 window for mic-osd.

Creates an overlay window for displaying audio visualizations.
Positioning is handled by Hyprland window rules (windowrules-mic-osd.conf)
matching on app_id "mic-osd" set via GLib.set_prgname().
"""

import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')

from gi.repository import Gtk, Gdk, GLib

# Set app_id so Hyprland window rules can match this window
GLib.set_prgname("mic-osd")


class OSDWindow(Gtk.Window):
    """
    An overlay window for displaying audio visualizations.

    Positioning (float, pin, nofocus, bottom-center) is handled by
    Hyprland window rules matching class "mic-osd".
    """

    def __init__(self, visualization, width=300, height=60):
        super().__init__()

        self.visualization = visualization
        self._width = width
        self._height = height

        self._setup_window()
        self._setup_drawing_area()

    def _setup_window(self):
        """Configure basic window properties."""
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_default_size(self._width, self._height)

        # Make window transparent
        self.add_css_class('mic-osd-window')

    def _setup_drawing_area(self):
        """Set up the Cairo drawing area."""
        self.drawing_area = Gtk.DrawingArea()
        self.drawing_area.set_content_width(self._width)
        self.drawing_area.set_content_height(self._height)
        self.drawing_area.set_draw_func(self._on_draw)
        self.set_child(self.drawing_area)

    def _on_draw(self, area, cr, width, height):
        """Called when the drawing area needs to be redrawn."""
        self.visualization.draw_background(cr, width, height)
        self.visualization.draw(cr, width, height)

    def update(self, level: float, samples=None):
        """Update the visualization with new audio data."""
        self.visualization.update(level, samples)
        self.drawing_area.queue_draw()

    def set_visualization(self, visualization):
        """Change the visualization type."""
        self.visualization = visualization
        self.drawing_area.queue_draw()

    def make_click_through(self):
        """Make the window click-through (input passes to windows below)."""
        pass


def load_css(css_path=None):
    """Load CSS styling for the OSD."""
    css_provider = Gtk.CssProvider()

    default_css = """
    .mic-osd-window {
        background-color: transparent;
    }
    """

    if css_path:
        try:
            css_provider.load_from_path(css_path)
        except GLib.Error:
            css_provider.load_from_string(default_css)
    else:
        css_provider.load_from_string(default_css)

    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(),
        css_provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
