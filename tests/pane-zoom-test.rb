# A zoomed pane under the boxed border model.
#
# resize-pane -Z saves the layout and builds a fresh one holding the zoomed
# pane alone (window_zoom -> layout_init), so a zoomed pane is an ordinary
# single pane layout and must be boxed like any other pane: it covers the
# window less one cell of border all round, not the whole window.
#
# Unzooming must put the saved layout back exactly as it was, so the same
# scene has to come out the other side.
#
# Run directly:  ruby pane-zoom-test.rb
# Or with rake:  rake tests TEST=pane-zoom

require 'minitest/autorun'
require_relative 'tmux_scene'

class PaneZoomTest < Minitest::Test
  include SceneAssertions

  CONF = "set -w -g pane-border-lines single\n".freeze

  # A 2x2 grid in a 12x8 window: four 6x4 boxes with 4x2 of content.
  TILED_2X2 = <<~LAYOUT.freeze
    ┌────┐┌────┐
    │....││....│
    │....││....│
    └────┘└────┘
    ┌────┐┌────┐
    │....││....│
    │....││....│
    └────┘└────┘
  LAYOUT

  # The zoomed pane is the only pane in the layout, so it gets everything
  # inside the window's own border: 10x6 of content in a 12x8 window.
  ZOOMED = <<~LAYOUT.freeze
    ┌──────────┐
    │..........│
    │..........│
    │..........│
    │..........│
    │..........│
    │..........│
    └──────────┘
  LAYOUT

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  # Build the 2x2 grid used by every test here.
  def tiled_2x2_scene
    @scene = TmuxScene.new(width: 12, height: 8, conf: CONF).start
    @scene.split_window('-h')
    @scene.split_window('-v')
    @scene.cmd('select-pane', '-t0')
    @scene.split_window('-v')
    @scene.cmd('select-layout', 'tiled')
    @scene.fill_panes
    @scene
  end

  # Zooming the first pane of a 2x2 leaves one boxed pane filling the window.
  def test_zoom_first_pane_of_2x2_is_boxed
    tiled_2x2_scene
    @scene.capture
    assert_layout @scene, TILED_2X2

    @scene.cmd('resize-pane', '-Z', '-t0')
    @scene.refill_panes
    @scene.capture

    assert_layout @scene, ZOOMED
    assert_equal '1', @scene.cmd('display', '-p', '#{window_zoomed_flag}')

    assert @scene.alive?, 'inner server died'
  end

  # Unzooming restores the grid, borders and pane sizes included.
  def test_unzoom_restores_the_2x2
    tiled_2x2_scene
    @scene.cmd('resize-pane', '-Z', '-t0')
    @scene.cmd('resize-pane', '-Z', '-t0')
    @scene.refill_panes
    @scene.capture

    assert_layout @scene, TILED_2X2
    assert_equal '0', @scene.cmd('display', '-p', '#{window_zoomed_flag}')

    assert @scene.alive?, 'inner server died'
  end

  # Resizing the window while zoomed keeps the single box on the window edge,
  # and unzooming afterwards still gives a grid that fits the new window.
  def test_zoomed_pane_follows_a_window_resize
    tiled_2x2_scene
    @scene.cmd('resize-pane', '-Z', '-t0')
    @scene.resize_window(width: 10, height: 6)
    @scene.refill_panes
    @scene.capture

    assert_layout @scene, <<~LAYOUT
      ┌────────┐
      │........│
      │........│
      │........│
      │........│
      └────────┘
    LAYOUT

    @scene.cmd('resize-pane', '-Z', '-t0')
    @scene.refill_panes
    @scene.capture

    # 10 - 2*2 = 6 content columns per row and 6 - 2*2 = 2 content rows per
    # column, so four 3x1 panes.
    assert_layout @scene, <<~LAYOUT
      ┌───┐┌───┐
      │...││...│
      └───┘└───┘
      ┌───┐┌───┐
      │...││...│
      └───┘└───┘
    LAYOUT

    assert @scene.alive?, 'inner server died'
  end
end
