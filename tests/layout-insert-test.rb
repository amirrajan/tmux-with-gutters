# Cells that come back into the tiled layout, and sizes asked for as a
# percentage of the window.
#
# Both go through code that still measures against the window rather than
# against the layout, which is the window less LAYOUT_BORDER all round
# (layout_window_area, added in 29755bd5):
#
#   layout_insert_tile   the "only pane in the layout" case sets the root cell
#                        to w->sx by w->sy at 0,0, so a floating pane put back
#                        into an otherwise empty window is given the whole
#                        window and no room for its own border. Every other
#                        path takes space off a neighbour and stays inset, so
#                        this is only reachable with one pane.
#
#   layout_get_tiled_cell  a full size split with -l or -p takes its
#                        percentage of w->sx or w->sy, while the space the
#                        split actually has to divide is the layout less one
#                        LAYOUT_SEPARATOR, so -l 50% does not halve anything.
#
# Run directly:  ruby layout-insert-test.rb
# Or with rake:  rake tests TEST=layout-insert

require 'minitest/autorun'
require_relative 'tmux_scene'

class LayoutInsertTest < Minitest::Test
  include SceneAssertions

  CONF = "set -w -g pane-border-lines single\n".freeze

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  def start_scene(width:, height:)
    @scene = TmuxScene.new(width: width, height: height, conf: CONF).start
  end

  # break-pane -W lifts a pane out of the layout; join-pane with the same pane
  # as source and target puts it back.
  def float(target = '-s0')
    @scene.cmd('break-pane', '-W', target)
    @scene
  end

  def tile(index = 0)
    @scene.cmd('join-pane', "-s#{index}", "-t#{index}")
    @scene
  end

  # The only pane of the window, floated and put back, must be the boxed
  # single pane layout_init would have built: a 20x8 window less one cell all
  # round is 18x6 at 1,1.
  def test_untiling_the_only_pane_leaves_room_for_its_border
    start_scene(width: 20, height: 8)
    float
    tile

    assert_geometry @scene, "0 1 1 18 6\n"
  end

  # The same pane, drawn: it is boxed like any other single pane.
  def test_untiled_only_pane_is_boxed
    start_scene(width: 10, height: 4)
    float
    tile
    @scene.fill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────┐
      │........│
      │........│
      └────────┘
    LAYOUT
  end

  # With a sibling to take the space from, the pane comes back into a cell of
  # the tiled layout and both stay inside the window. This one passes already
  # and is here to say that it is the root case above that is special.
  def test_untiling_one_of_two_panes_splits_the_layout
    start_scene(width: 20, height: 8)
    @scene.split_window('-h')
    float
    tile

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 8 6
      1 11 1 8 6
    GEOMETRY
  end

  # A full size split of half the window. The layout of a 20x12 window is
  # 18x10, and the two rows cost LAYOUT_SEPARATOR between them, so there are 8
  # content rows to divide: half each is 4 and 4.
  def test_full_size_percentage_split_halves_the_usable_area
    start_scene(width: 20, height: 12)
    @scene.split_window('-v', '-f', '-l', '50%')

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 18 4
      1 1 7 18 4
    GEOMETRY
  end

  # The same across, so the failure names an axis: 18 - 2 = 16 content
  # columns, 8 each.
  def test_full_size_percentage_split_halves_the_usable_area_across
    start_scene(width: 20, height: 8)
    @scene.split_window('-h', '-f', '-l', '50%')

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 8 6
      1 11 1 8 6
    GEOMETRY
  end
end
