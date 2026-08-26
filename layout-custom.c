/* $OpenBSD: layout-custom.c,v 1.38 2026/07/16 12:36:58 nicm Exp $ */

/*
 * Copyright (c) 2010 Nicholas Marriott <nicholas.marriott@gmail.com>
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

#include <ctype.h>
#include <string.h>

#include "tmux.h"

static struct layout_cell	*layout_find_bottomright(struct layout_cell *);
static u_short			 layout_checksum(const char *);
static int			 layout_append(struct layout_cell *, char *,
				     size_t);
static int			 layout_construct(struct layout_cell *,
				     const char **, struct layout_cell **);
static void			 layout_assign(struct window_pane **,
				     struct layout_cell *, int);

/* Find the bottom-right cell. */
static struct layout_cell *
layout_find_bottomright(struct layout_cell *lc)
{
	if (lc->type == LAYOUT_WINDOWPANE)
		return (lc);
	lc = TAILQ_LAST(&lc->cells, layout_cells);
	return (layout_find_bottomright(lc));
}

/* Calculate layout checksum. */
static u_short
layout_checksum(const char *layout)
{
	u_short	csum;

	csum = 0;
	for (; *layout != '\0'; layout++) {
		csum = (csum >> 1) + ((csum & 1) << 15);
		csum += *layout;
	}
	return (csum);
}

/* Dump layout as a string. */
char *
layout_dump(struct window *w, struct layout_cell *root)
{
	char			 layout[8192], *out;
	int			 bracket = 0;
	struct window_pane	*wp;

	*layout = '\0';
	if (layout_append(root, layout, sizeof layout) != 0)
		return (NULL);

	TAILQ_FOREACH(wp, &w->z_index, zentry) {
		if (!window_pane_is_floating(wp))
			break;
		if (!bracket) {
			strlcat(layout, "<", sizeof layout);
			bracket = 1;
		}
		if (layout_append(wp->layout_cell, layout, sizeof layout) != 0)
			return (NULL);
		strlcat(layout, ",", sizeof layout);
	}
	if (bracket)
		layout[strlen(layout) - 1] = '>';

	xasprintf(&out, "%04hx,%s", layout_checksum(layout), layout);
	return (out);
}

/* Append information for a single cell. */
static int
layout_append(struct layout_cell *lc, char *buf, size_t len)
{
	struct layout_cell     *lcchild;
	char			tmp[64];
	size_t			tmplen;
	const char	       *brackets = "][";

	if (len == 0)
		return (-1);
	if (lc == NULL)
		return (0);
	if (lc->wp != NULL) {
		tmplen = xsnprintf(tmp, sizeof tmp, "%ux%u,%d,%d,%u",
		    lc->g.sx, lc->g.sy, lc->g.xoff, lc->g.yoff, lc->wp->id);
	} else {
		tmplen = xsnprintf(tmp, sizeof tmp, "%ux%u,%d,%d",
		    lc->g.sx, lc->g.sy, lc->g.xoff, lc->g.yoff);
	}
	if (tmplen > (sizeof tmp) - 1)
		return (-1);
	if (strlcat(buf, tmp, len) >= len)
		return (-1);

	switch (lc->type) {
	case LAYOUT_LEFTRIGHT:
		brackets = "}{";
		/* FALLTHROUGH */
	case LAYOUT_TOPBOTTOM:
		if (strlcat(buf, &brackets[1], len) >= len)
			return (-1);
		TAILQ_FOREACH(lcchild, &lc->cells, entry) {
			if (layout_append(lcchild, buf, len) != 0)
				return (-1);
			if (strlcat(buf, ",", len) >= len)
				return (-1);
		}
		buf[strlen(buf) - 1] = brackets[0];
		break;
	case LAYOUT_WINDOWPANE:
		break;
	}

	return (0);
}

/* Check layout sizes fit. */
static int
layout_check(struct layout_cell *lc)
{
	struct layout_cell	*lcchild;
	u_int			 n = 0;

	switch (lc->type) {
	case LAYOUT_WINDOWPANE:
		break;
	case LAYOUT_LEFTRIGHT:
		TAILQ_FOREACH(lcchild, &lc->cells, entry) {
			if (lcchild->g.sy != lc->g.sy) {
				log_debug("%s: child %ux%u is not as tall as "
				    "its parent %ux%u", __func__,
				    lcchild->g.sx, lcchild->g.sy, lc->g.sx,
				    lc->g.sy);
				return (0);
			}
			if (!layout_check(lcchild))
				return (0);
			n += lcchild->g.sx + LAYOUT_SEPARATOR;
		}
		n -= LAYOUT_SEPARATOR;
		if (n != lc->g.sx) {
			log_debug("%s: LEFTRIGHT children and separators are "
			    "%u wide, parent is %u", __func__, n,
			    lc->g.sx);
			return (0);
		}
		break;
	case LAYOUT_TOPBOTTOM:
		TAILQ_FOREACH(lcchild, &lc->cells, entry) {
			if (lcchild->g.sx != lc->g.sx) {
				log_debug("%s: child %ux%u is not as wide as "
				    "its parent %ux%u", __func__,
				    lcchild->g.sx, lcchild->g.sy, lc->g.sx,
				    lc->g.sy);
				return (0);
			}
			if (!layout_check(lcchild))
				return (0);
			n += lcchild->g.sy + LAYOUT_SEPARATOR;
		}
		n -= LAYOUT_SEPARATOR;
		if (n != lc->g.sy) {
			log_debug("%s: TOPBOTTOM children and separators are "
			    "%u tall, parent is %u", __func__, n,
			    lc->g.sy);
			return (0);
		}
		break;
	}
	return (1);
}

/* Parse a layout string and arrange window as layout. */
int
layout_parse(struct window *w, const char *layout, char **cause)
{
	struct layout_cell	*lcchild, *tiled_lc = NULL;
	struct window_pane	*wp;
	u_int			 npanes, ncells, sx = 0, sy = 0, usx, usy;
	u_short			 csum;
	int			 n = 0;

	log_debug("%s: @%u %ux%u: %s", __func__, w->id, w->sx, w->sy, layout);

	/* Check validity. */
	if (sscanf(layout, "%hx,%n", &csum, &n) != 1 || n != 5) {
		log_debug("%s: no checksum", __func__);
		*cause = xstrdup("invalid layout");
		return (-1);
	}
	layout += n;
	if (csum != layout_checksum(layout)) {
		log_debug("%s: checksum is %04hx, wanted %04hx", __func__,
		    layout_checksum(layout), csum);
		*cause = xstrdup("invalid layout");
		return (-1);
	}

	/* Build the layout. */
	if (layout_construct(NULL, &layout, &tiled_lc) != 0) {
		log_debug("%s: cells do not add up, see layout_check", __func__);
		*cause = xstrdup("invalid layout");
		return (-1);
	}
	if (tiled_lc == NULL) {
		/* A stub layout cell for an empty window. */
		tiled_lc = layout_create_cell(NULL);
		tiled_lc->type = LAYOUT_LEFTRIGHT;
		layout_window_area(w, &usx, &usy);
		layout_set_size(tiled_lc, usx, usy, LAYOUT_BORDER,
		    LAYOUT_BORDER);
	}
	if (*layout != '\0') {
		*cause = xstrdup("invalid layout");
		goto fail;
	}

	/* Check this window will fit into the layout. */
	npanes = window_count_panes(w, 1);
	for (;;) {
		ncells = layout_count_cells(tiled_lc);
		if (npanes > ncells) {
			xasprintf(cause, "have %u panes but need %u", npanes,
			    ncells);
			goto fail;
		}
		if (npanes == ncells)
			break;

		/*
		 * Fewer panes than cells, close the bottom right until none
		 * remain.
		 */
		lcchild = layout_find_bottomright(tiled_lc);
		layout_destroy_cell(w, lcchild, &tiled_lc);
	}

	/*
	 * It appears older versions of tmux were able to generate layouts with
	 * an incorrect top cell size - if it is larger than the top child then
	 * correct that (if this is still wrong the check code will catch it).
	 */

	switch (tiled_lc->type) {
	case LAYOUT_WINDOWPANE:
		break;
	case LAYOUT_LEFTRIGHT:
		TAILQ_FOREACH(lcchild, &tiled_lc->cells, entry) {
			sy = lcchild->g.sy;
			sx += lcchild->g.sx + LAYOUT_SEPARATOR;
		}
		sx -= LAYOUT_SEPARATOR;
		break;
	case LAYOUT_TOPBOTTOM:
		TAILQ_FOREACH(lcchild, &tiled_lc->cells, entry) {
			sx = lcchild->g.sx;
			sy += lcchild->g.sy + LAYOUT_SEPARATOR;
		}
		sy -= LAYOUT_SEPARATOR;
		break;
	}
	if (tiled_lc->type != LAYOUT_WINDOWPANE &&
	    (tiled_lc->g.sx != sx || tiled_lc->g.sy != sy)) {
		layout_print_cell(tiled_lc, __func__, 0);
		tiled_lc->g.sx = sx; tiled_lc->g.sy = sy;
	}

	/* Check the new layout. */
	if (!layout_check(tiled_lc)) {
		*cause = xstrdup("size mismatch after applying layout");
		goto fail;
	}

	/* Resize window to the layout size, plus the border at its edge. */
	if (sx != 0 && sy != 0)
		layout_fit_window(w, tiled_lc);

	/* Destroy the old layout and swap to the new. */
	layout_free_cell(w->layout_root, 0);
	w->layout_root = tiled_lc;

	/* Assign the panes into the cells. */
	wp = TAILQ_FIRST(&w->panes);
	if (tiled_lc != NULL)
		layout_assign(&wp, tiled_lc, 0);

        /* Fix pane z-indexes. */
        while (!TAILQ_EMPTY(&w->z_index)) {
                wp = TAILQ_FIRST(&w->z_index);
		TAILQ_REMOVE(&w->z_index, wp, zentry);
	}
	layout_fix_zindexes(w, tiled_lc);

	/* Update pane offsets and sizes. */
	layout_fix_offsets(w);
	layout_fix_panes(w, NULL);
	recalculate_sizes();
	layout_print_cell(tiled_lc, __func__, 0);

	events_fire_window("window-layout-changed", w);

	return (0);

fail:
	layout_free_cell(tiled_lc, 0);
	return (-1);
}

/* Assign panes into cells. */
static void
layout_assign(struct window_pane **wp, struct layout_cell *lc, int flags)
{
	struct layout_cell	*lcchild;

	if (lc == NULL)
		return;

	switch (lc->type) {
	case LAYOUT_WINDOWPANE:
		layout_make_leaf(lc, *wp);
		lc->flags |= flags;
		*wp = TAILQ_NEXT(*wp, entry);
		return;
	case LAYOUT_LEFTRIGHT:
	case LAYOUT_TOPBOTTOM:
		TAILQ_FOREACH(lcchild, &lc->cells, entry)
			layout_assign(wp, lcchild, flags);
		return;
	}
}

static struct layout_cell *
layout_construct_cell(struct layout_cell *lcparent, const char **layout)
{
	struct layout_cell     *lc;
	u_int			sx, sy;
	int			xoff, yoff;
	const char	       *saved;

	if (!isdigit((u_char) **layout))
		return (NULL);
	if (sscanf(*layout, "%ux%u,%d,%d", &sx, &sy, &xoff, &yoff) != 4)
		return (NULL);

	while (isdigit((u_char) **layout))
		(*layout)++;
	if (**layout != 'x')
		return (NULL);
	(*layout)++;
	while (isdigit((u_char) **layout))
		(*layout)++;
	if (**layout != ',')
		return (NULL);
	(*layout)++;
	while (isdigit((u_char) **layout))
		(*layout)++;
	if (**layout != ',')
		return (NULL);
	(*layout)++;
	while (isdigit((u_char) **layout))
		(*layout)++;
	if (**layout == ',') {
		saved = *layout;
		(*layout)++;
		while (isdigit((u_char) **layout))
			(*layout)++;
		if (**layout == 'x')
			*layout = saved;
	}

	lc = layout_create_cell(lcparent);
	lc->g.sx = sx;
	lc->g.sy = sy;
	lc->g.xoff = xoff;
	lc->g.yoff = yoff;

	return (lc);
}

/*
 * Given a character string layout, recursively construct cells.
 * Possible return values:
 *  lc LAYOUT_WINDOWPANE, no children
 *  lc LAYOUT_LEFTRIGHT or LAYOUT_TOPBOTTOM, with children
 */
static int
layout_construct(struct layout_cell *lcparent, const char **layout,
    struct layout_cell **lc)
{
	struct layout_cell	*lcchild;

	*lc = layout_construct_cell(lcparent, layout);
	if (*lc == NULL)
		return (-1);

	switch (**layout) {
	case ',':
	case '}':
	case ']':
	case '>':
	case '\0':
		return (0);
	case '{':
		(*lc)->type = LAYOUT_LEFTRIGHT;
		break;
	case '[':
		(*lc)->type = LAYOUT_TOPBOTTOM;
		break;
	default:
		goto fail;
	}

	do {
		(*layout)++;
		if (layout_construct(*lc, layout, &lcchild) != 0)
			goto fail;
		TAILQ_INSERT_TAIL(&(*lc)->cells, lcchild, entry);
	} while (**layout == ',');

	switch ((*lc)->type) {
	case LAYOUT_LEFTRIGHT:
		if (**layout != '}')
			goto fail;
		break;
	case LAYOUT_TOPBOTTOM:
		if (**layout != ']')
			goto fail;
		break;
	default:
		goto fail;
	}
	(*layout)++;

	return (0);

fail:
	layout_free_cell(*lc, 0);
	return (-1);
}
