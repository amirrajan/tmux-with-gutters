# Layout strings under the boxed border model.
#
# layout.c and layout-set.c were both moved onto LAYOUT_BORDER and
# LAYOUT_SEPARATOR (29755bd5, cace349a, ccbbc466), but layout-custom.c was
# not: layout_check still adds one cell per interior boundary and nothing for
# the window edge, and layout_parse resizes the window to the root cell size
# without adding the outer border back. So the two halves of the same format
# disagree - layout_dump writes cells that are two apart and inset by one,
# layout_parse reads them as if they were one apart and started at 0,0.
#
# What that costs, all through #{window_layout}, which is what select-layout
# takes and what every save/restore tool stores:
#
#   - a two pane layout re-applied to itself moves and resizes its panes, and
#     the last pane's border ends up outside the window,
#   - a 2x2 is rejected outright with "size mismatch after applying layout",
#   - a layout restored into another window of the same size comes out one
#     cell different from the window it was taken from.
#
# These are the smallest cases for each, on pane rectangles rather than a
# rendered picture, so a failure names the arithmetic and not the drawing.
#
# Run directly:  ruby layout-custom-test.rb
# Or with rake:  rake tests TEST=layout-custom

require 'minitest/autorun'
require_relative 'tmux_scene'

class LayoutCustomTest < Minitest::Test
  include SceneAssertions

  CONF = "set -w -g pane-border-lines single\n".freeze

  # A 20x8 window is 18x6 of layout, which divides evenly on both axes: two
  # panes across are 8 wide (8 + 2 + 8), two panes down are 2 high (2 + 2 + 2).
  WIDTH = 20
  HEIGHT = 8

  # Every test here works on the same window, so it is started once.
  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = TmuxScene.new(width: WIDTH, height: HEIGHT, conf: CONF).start
  end

  def teardown
    @scene&.stop
  end

  # Apply a window's own layout string back to it. A layout is meant to be a
  # complete description of the window it came from, so this must be a no-op:
  # accepted, same panes, same string.
  def assert_round_trips(scene)
    before_layout = scene.layout_string
    before_geometry = scene.geometry

    begin
      scene.cmd('select-layout', before_layout)
    rescue RuntimeError => e
      flunk "select-layout rejected the window's own layout\n\n" \
            "layout: #{before_layout}\n\n" \
            "geometry (index left top width height):\n" \
            "#{indent(before_geometry)}\n\n#{e.message}"
    end

    assert_equal before_geometry, scene.geometry,
                 "applying a window's own layout moved its panes\n\n" \
                 "layout: #{before_layout}\n" \
                 "after : #{scene.layout_string}\n\n" \
                 "before (index left top width height):\n" \
                 "#{indent(before_geometry)}\n\n" \
                 "after:\n#{indent(scene.geometry)}\n\n" \
                 "window: #{scene.window_summary}"
    assert_equal before_layout, scene.layout_string,
                 'applying a window\'s own layout changed the layout string'
  end

  # Every pane, and the border it owns, must be inside the window: a pane at
  # xoff spans xoff - 1 to xoff + sx, so the last of those must still be a
  # cell of the window.
  def assert_panes_inside_window(scene)
    rows = scene.cmd('list-panes', '-F',
                     '#{pane_index} #{pane_left} #{pane_top} ' \
                     '#{pane_right} #{pane_bottom}').split("\n")
    width, height = scene.cmd('display', '-p',
                              '#{window_width} #{window_height}')
                         .split.map(&:to_i)

    rows.each do |row|
      index, left, top, right, bottom = row.split.map(&:to_i)
      inside = left >= 1 && top >= 1 && right <= width - 2 &&
               bottom <= height - 2
      assert inside,
             "pane #{index} at #{left},#{top}-#{right},#{bottom} has no room " \
             "for its border in a #{width}x#{height} window\n\n" \
             "layout: #{scene.layout_string}\n" \
             "geometry (index left top width height):\n" \
             "#{indent(scene.geometry)}"
    end
  end

  # Two panes side by side: 18 - 2 = 16 content columns, 8 each.
  def test_horizontal_split_layout_string_round_trips
    @scene.split_window('-h')

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 8 6
      1 11 1 8 6
    GEOMETRY

    assert_round_trips @scene
    assert_panes_inside_window @scene
  end

  # Two panes stacked: 6 - 2 = 4 content rows, 2 each.
  def test_vertical_split_layout_string_round_trips
    @scene.split_window('-v')

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 18 2
      1 1 5 18 2
    GEOMETRY

    assert_round_trips @scene
    assert_panes_inside_window @scene
  end

  # A 2x2, which is where the geometry check has a nesting level to disagree
  # about as well as a row of siblings.
  def test_tiled_2x2_layout_string_round_trips
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.select_pane('-t0')
    @scene.split_window('-v')

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 8 2
      1 1 5 8 2
      2 11 1 8 2
      3 11 5 8 2
    GEOMETRY

    assert_round_trips @scene
    assert_panes_inside_window @scene
  end

  # The point of the format: a layout taken from one window and applied to
  # another of the same size must reproduce the panes it came from, not
  # something a cell out. The panes are made uneven first so that a wrong
  # answer cannot look right by symmetry.
  def test_layout_string_restores_the_same_panes_in_another_window
    @scene.split_window('-h')
    @scene.cmd('resize-pane', '-t0', '-x', '5')

    layout = @scene.layout_string
    wanted = @scene.geometry

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 5 6
      1 8 1 11 6
    GEOMETRY

    @scene.cmd('new-window')
    @scene.cmd('resizew', '-x', WIDTH.to_s, '-y', HEIGHT.to_s)
    @scene.split_window('-h')
    @scene.cmd('select-layout', layout)

    assert_equal wanted, @scene.geometry,
                 "restoring a layout gave different panes\n\n" \
                 "layout: #{layout}\n" \
                 "restored as: #{@scene.layout_string}\n\n" \
                 "wanted (index left top width height):\n" \
                 "#{indent(wanted)}\n\n" \
                 "got:\n#{indent(@scene.geometry)}"
  end

  private

  def indent(text)
    text.to_s.split("\n").map { |line| "  #{line}" }.join("\n")
  end
end
