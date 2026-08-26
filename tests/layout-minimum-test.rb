# The smallest window a layout fits in.
#
# Boxed borders need LAYOUT_BORDER (1) on each window edge and
# LAYOUT_SEPARATOR (2) between siblings, so n panes across need
#
#     n + (n - 1) * LAYOUT_SEPARATOR + 2 * LAYOUT_BORDER
#
# cells on that axis: 9 for three panes, 12 for four. Under the shared border
# model a boundary cost one cell instead of three, so this bites much earlier
# than it does upstream.
#
# Nothing clamps the window to that minimum. layout_resize refuses to shrink
# the cells any further and window_resize shrinks the window anyway, so the
# layout keeps the size it had and the panes on the far side end up with their
# border outside the window, and then outside the window themselves. Probed on
# a 40x8 window with three panes split -h:
#
#     x=9 -> panes at 1 4 7, width 1     needs 9, fits
#     x=8 -> pane 2's border at column 8 is off the window
#     x=7 -> pane 2 itself is outside the window
#
# and the same on the other axis with -v, and at 12/11/10 with four panes.
#
# This is the same shape of bug as the three call sites of layout-insert-test.rb
# and layout-custom-test.rb: a size computed without the boxed invariant. The
# fix wants a layout_minimum_window_size next to layout_fit_window, called
# wherever a window is resized.
#
# The assertion is assert_panes_inside_window from SceneAssertions: every pane
# plus its own border has to be a rectangle of the window. What tmux does
# instead of shrinking - clamp the window, drop panes, let the layout overflow
# and clip - is not pinned here, only that the panes that exist are drawable.
#
# Run directly:  ruby layout-minimum-test.rb
# Or with rake:  rake tests TEST=layout-minimum

require 'minitest/autorun'
require_relative 'tmux_scene'

class LayoutMinimumTest < Minitest::Test
  include SceneAssertions

  CONF = "set -w -g pane-border-lines single\n".freeze

  LAYOUT_BORDER = 1
  LAYOUT_SEPARATOR = 2

  # The window has to start big enough for the splits to be taken at all, and
  # is shrunk from there.
  START_WIDTH = 40
  START_HEIGHT = 20

  def setup
    skip "no #{TmuxScene::SHELL}" unless TmuxScene.supported?
    @scene = nil
  end

  def teardown
    @scene&.stop
  end

  # n panes on one axis need this many cells of that axis.
  def minimum_for(panes)
    panes + (panes - 1) * LAYOUT_SEPARATOR + 2 * LAYOUT_BORDER
  end

  # A window with panes panes split in direction ('-h' or '-v'), ready to be
  # shrunk.
  def start_split_scene(panes, direction)
    @scene = TmuxScene.new(width: START_WIDTH, height: START_HEIGHT,
                           conf: CONF).start
    (panes - 1).times { @scene.split_window(direction) }
    assert_equal panes, @scene.pane_indexes.size, 'splits were not taken'
    @scene
  end

  # Shrink the axis the panes are split along to size, leaving the other axis
  # alone, and check every pane is still drawable.
  def assert_fits_at(size, axis:)
    if axis == :width
      @scene.resize_window(width: size, height: START_HEIGHT)
    else
      @scene.resize_window(width: START_WIDTH, height: size)
    end

    assert_panes_inside_window @scene
  end

  # The fence: at exactly the minimum everything fits, and this passes today.
  # It is here so that a fix that clamps too hard, or that gives a boundary a
  # fourth cell, fails as well.
  def test_three_panes_across_fit_at_the_minimum_width
    start_split_scene(3, '-h')

    assert_equal 9, minimum_for(3)
    assert_fits_at 9, axis: :width

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 1 18
      1 4 1 1 18
      2 7 1 1 18
    GEOMETRY
  end

  # One cell under the minimum: the layout does not shrink, the window does,
  # and the last pane's border is off the window (right = 7 in a 8 wide
  # window, where the last usable column is 6).
  def test_three_panes_across_stay_inside_a_window_one_cell_too_narrow
    start_split_scene(3, '-h')

    assert_fits_at minimum_for(3) - 1, axis: :width
  end

  # Two cells under, which is where the pane itself, not only its border, is
  # outside the window.
  def test_three_panes_across_stay_inside_a_window_two_cells_too_narrow
    start_split_scene(3, '-h')

    assert_fits_at minimum_for(3) - 2, axis: :width
  end

  # The same on the other axis, which is separate arithmetic in layout_resize
  # and in every set layout.
  def test_three_panes_down_fit_at_the_minimum_height
    start_split_scene(3, '-v')

    assert_fits_at 9, axis: :height

    assert_geometry @scene, <<~GEOMETRY
      0 1 1 38 1
      1 1 4 38 1
      2 1 7 38 1
    GEOMETRY
  end

  def test_three_panes_down_stay_inside_a_window_one_cell_too_short
    start_split_scene(3, '-v')

    assert_fits_at minimum_for(3) - 1, axis: :height
  end

  def test_three_panes_down_stay_inside_a_window_two_cells_too_short
    start_split_scene(3, '-v')

    assert_fits_at minimum_for(3) - 2, axis: :height
  end

  # A fourth pane moves the minimum by LAYOUT_SEPARATOR + 1, so a fix that
  # hard codes the three pane number rather than counting boundaries fails
  # here.
  def test_four_panes_across_fit_at_the_minimum_width
    start_split_scene(4, '-h')

    assert_equal 12, minimum_for(4)
    assert_fits_at 12, axis: :width
  end

  def test_four_panes_across_stay_inside_a_window_one_cell_too_narrow
    start_split_scene(4, '-h')

    assert_fits_at minimum_for(4) - 1, axis: :width
  end

  def test_four_panes_across_stay_inside_a_window_two_cells_too_narrow
    start_split_scene(4, '-h')

    assert_fits_at minimum_for(4) - 2, axis: :width
  end
end
