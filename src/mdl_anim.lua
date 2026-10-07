-- MDL panel animations (test, 1.8.0). Pure: computes overlay rectangles for
-- the current time; the renderer keeps them as retained GUI rects and moves
-- them with Gui.update_rect, so an animation frame costs a few update calls
-- instead of a panel rebuild.
--   open    the panel unfolds from the top (a cover shrinks downwards, with
--           a bright edge line), 0.28 s
--   select  the selection bar glides to the new row, 0.10 s
--   blink   archive theme: a cursor block after the title, 0.55 s period
local A = {}

A.OPEN, A.GLIDE, A.BLINK = 0.28, 0.10, 0.55

function A.ease_out(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    local u = 1 - t
    return 1 - u * u * u
end

function A.new()
    local self = {}
    local opened, sel = nil, nil

    -- Panel became visible.
    function self.open(now) opened = now end
    function self.reset() opened, sel = nil, nil end

    -- Overlay items for the geometry of the last build:
    --   g.panel = {x, y, w, h}; g.sel = {x, y, w, h, inverted, page} or nil;
    --   g.title_end = {x, y, h} or nil (blink position).
    -- colours = function(name) -> {a, r, g, b}. Returns items, key, busy:
    -- key changes whenever the items do; busy is true while something moves.
    function self.items(g, now, colours, options)
        options = options or {}
        local items, busy, parts = {}, false, {}
        local function rect(name, x, y, w, h, color, z)
            items[#items + 1] = {name = name, rect = true, x = x, y = y, w = w, h = h, color = color, z = z}
            parts[#parts + 1] = string.format('%s:%.1f,%.1f,%.1f,%.1f,%d', name, x, y, w, h, color[1])
        end
        -- Selection glide.
        local target = g.sel
        if target then
            if not sel or sel.page ~= target.page or sel.inverted ~= target.inverted then
                sel = {from = target.y, to = target.y, start = now, page = target.page, inverted = target.inverted}
            elseif sel.to ~= target.y then
                local current = sel.from + (sel.to - sel.from) * A.ease_out((now - sel.start) / A.GLIDE)
                sel.from, sel.to, sel.start = current, target.y, now
            end
            local t = (now - sel.start) / A.GLIDE
            local y = sel.from + (sel.to - sel.from) * A.ease_out(t)
            if t < 1 then busy = true end
            if target.inverted then
                rect('sel_fill', target.x, y, target.w, target.h, colours('select_fill'), 901)
                local m = target.marker or 8
                rect('sel_mark', target.x + 5 * (target.s or 1), y + (target.h - m) / 2, m, m, colours('select_text'), 902)
            else
                rect('sel_fill', target.x, y, target.w, target.h, colours('hover'), 901)
                rect('sel_mark', target.x, y, 4 * (target.s or 1), target.h, colours('select'), 902)
            end
        else
            sel = nil
        end
        -- Open: cover shrinking towards the bottom, bright edge on top of it.
        if opened and g.panel then
            local t = (now - opened) / A.OPEN
            if t < 1 then
                busy = true
                local p = g.panel
                local covered = p.h * (1 - A.ease_out(t))
                rect('open_cover', p.x, p.y, p.w, covered, colours('back'), 920)
                local edge = colours('yellow')
                local fade = math.floor(edge[1] * (1 - t))
                rect('open_edge', p.x, p.y + covered - 2, p.w, 3, {fade, edge[2], edge[3], edge[4]}, 921)
            else
                opened = nil
            end
        end
        -- Blink (archive theme only).
        if options.blink and g.title_end then
            local on = math.floor(now / A.BLINK) % 2 == 0
            local c = colours('yellow')
            local te = g.title_end
            rect('blink', te.x, te.y, te.h * 0.5, te.h, on and c or {0, c[2], c[3], c[4]}, 906)
        end
        return items, table.concat(parts, ';'), busy
    end
    return self
end

return A
