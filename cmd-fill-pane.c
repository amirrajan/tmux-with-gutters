/* $OpenBSD$ */

/*
 * Copyright (c) 2026 Nicholas Marriott <nicholas.marriott@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include <string.h>

#include "tmux.h"

/*
 * Fill a pane with a character. The pane keeps running whatever it was
 * running: this writes straight into the pane's screen, so it does not depend
 * on the process in the pane, and the process may of course draw over it
 * afterwards. Intended for checking what is drawn where, by hand or from a
 * test, without having to arrange for a program to produce the output.
 *
 * Note this writes the pane's own screen. A pane in a mode (copy mode, or the
 * pane numbers shown by display-panes) draws the mode's screen instead, so a
 * fill made while a mode is active is not visible until the mode ends.
 */

static enum cmd_retval	cmd_fill_pane_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_fill_pane_entry = {
	.name = "fill-pane",
	.alias = "fillp",

	.args = { "at:", 0, 1, NULL },
	.usage = "[-a] " CMD_TARGET_PANE_USAGE " [character]",

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_fill_pane_exec
};

/* Fill one pane with a character. */
static void
cmd_fill_pane_one(struct window_pane *wp, u_char ch)
{
	struct screen_write_ctx	 ctx;
	u_int			 x, y;

	screen_write_start_pane(&ctx, wp, NULL);
	screen_write_clearscreen(&ctx, 8);
	for (y = 0; y < screen_size_y(&wp->base); y++) {
		screen_write_cursormove(&ctx, 0, y, 0);
		for (x = 0; x < screen_size_x(&wp->base); x++)
			screen_write_putc(&ctx, &grid_default_cell, ch);
	}
	screen_write_cursormove(&ctx, 0, 0, 0);
	screen_write_stop(&ctx);

	wp->flags |= PANE_REDRAW;
}

static enum cmd_retval
cmd_fill_pane_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	struct cmd_find_state	*target = cmdq_get_target(item);
	struct window_pane	*wp = target->wp, *loopwp;
	const char		*value = args_string(args, 0);
	u_char			 ch = '.';

	if (value != NULL) {
		if (strlen(value) != 1) {
			cmdq_error(item, "not a single character: %s", value);
			return (CMD_RETURN_ERROR);
		}
		ch = value[0];
	}

	if (args_has(args, 'a')) {
		TAILQ_FOREACH(loopwp, &target->w->panes, entry)
			cmd_fill_pane_one(loopwp, ch);
		return (CMD_RETURN_NORMAL);
	}

	if (wp == NULL) {
		cmdq_error(item, "no pane to fill");
		return (CMD_RETURN_ERROR);
	}
	cmd_fill_pane_one(wp, ch);
	return (CMD_RETURN_NORMAL);
}
