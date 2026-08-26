# select-layout arithmetic under the boxed border model.
#
# The split path (split-window, resize-pane) already sizes cells with
# LAYOUT_BORDER/LAYOUT_SEPARATOR, so pane-border-edges-test.rb passes for
# layouts built by splitting. layout-set.c still uses the upstream "one shared
# border column between neighbours, nothing on the outside" arithmetic: it
# spends (n - 1) cells on separators and starts at 0,0 rather than spending
# 2 * LAYOUT_BORDER on the window edge and LAYOUT_SEPARATOR between siblings.
#
# These are the smallest cases that pin that down, one axis at a time, so a
# failure names the arithmetic rather than a whole 2x2 scene:
#
#   n panes on one axis of a W cell window get W - 2n cells of content in
#   total (2 for the window edge, 2 per interior boundary), distributed with
#   the remainder going to the later panes.
#
# Run directly:  ruby layout-set-test.rb
# Or with rake:  rake tests TEST=layout-set

require 'minitest/autorun'
require_relative 'tmux_scene'

class LayoutSetTest < Minitest::Test
  include SceneAssertions

  CONF = "set -w -g pane-border-lines single\n".freeze

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  # Build a window with n panes, then apply layout.
  def scene_with(width:, height:, panes:, layout:, split: '-h')
    @scene = TmuxScene.new(width: width, height: height, conf: CONF).start
    (panes - 1).times { @scene.split_window(split) }
    @scene.cmd('select-layout', layout)
    @scene.fill_panes
    @scene.capture
    @scene
  end

  # Two panes, even-horizontal: 10 - 2*2 = 6 content columns, 3 each.
  def test_even_horizontal_two_panes
    scene_with(width: 10, height: 4, panes: 2, layout: 'even-horizontal')

    assert_layout @scene, <<~LAYOUT
      ┌───┐┌───┐
      │...││...│
      │...││...│
      └───┘└───┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Three panes, even-horizontal: 14 - 2*3 = 8 content columns for three
  # panes, so 2, 3, 3 with the remainder going to the later panes.
  def test_even_horizontal_three_panes_uneven
    scene_with(width: 14, height: 4, panes: 3, layout: 'even-horizontal')

    assert_layout @scene, <<~LAYOUT
      ┌──┐┌───┐┌───┐
      │..││...││...│
      │..││...││...│
      └──┘└───┘└───┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Two panes, even-vertical: 6 - 2*2 = 2 content rows, 1 each.
  def test_even_vertical_two_panes
    scene_with(width: 10, height: 6, panes: 2, layout: 'even-vertical',
               split: '-v')

    assert_layout @scene, <<~LAYOUT
      ┌────────┐
      │........│
      └────────┘
      ┌────────┐
      │........│
      └────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # Three panes, even-vertical: 11 - 2*3 = 5 content rows, so 1, 2, 2.
  def test_even_vertical_three_panes_uneven
    scene_with(width: 8, height: 11, panes: 3, layout: 'even-vertical',
               split: '-v')

    assert_layout @scene, <<~LAYOUT
      ┌──────┐
      │......│
      └──────┘
      ┌──────┐
      │......│
      │......│
      └──────┘
      ┌──────┐
      │......│
      │......│
      └──────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # tiled with two panes is a single column of two rows, so it must agree with
  # even-vertical on the same window.
  def test_tiled_two_panes_is_one_column
    scene_with(width: 10, height: 6, panes: 2, layout: 'tiled', split: '-v')

    assert_layout @scene, <<~LAYOUT
      ┌────────┐
      │........│
      └────────┘
      ┌────────┐
      │........│
      └────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end

  # tiled with three panes: a 2x2 grid whose last row holds one full width
  # pane. Rows: 8 - 2*2 = 4 content rows, 2 each. Top row columns:
  # 14 - 2*2 = 10 content columns, 5 each. Bottom row: 14 - 2 = 12.
  def test_tiled_three_panes_last_row_spans
    scene_with(width: 14, height: 8, panes: 3, layout: 'tiled')

    assert_layout @scene, <<~LAYOUT
      ┌─────┐┌─────┐
      │.....││.....│
      │.....││.....│
      └─────┘└─────┘
      ┌────────────┐
      │............│
      │............│
      └────────────┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end
end
