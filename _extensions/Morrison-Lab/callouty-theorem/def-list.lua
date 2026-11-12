-- Opt-in companion of callouty-theorem; it runs first because callouty-theorem
-- consumes the definition nodes this filter lists.
-- Append a "Definitions on this page" list to the end of a page.
-- Every #def- div contributes one entry, linked to the div, in page order:
-- its numbered label ("Definition 3"), then its title in parentheses if it has one.
-- Opt in with `def-list: true` in the page or project metadata;
-- `def-list-title` overrides the heading text.
local entries = {}

-- A citation of the div's own id; Quarto's crossref stage resolves it to the
-- numbered label, as callouty-theorem does for the callout title.
local function label_cite(identifier)
  return pandoc.Cite(
    { pandoc.Str("@" .. identifier) },
    { pandoc.Citation(identifier, "AuthorInText") })
end

-- Keep the title's inlines (math, emphasis, code), but drop links:
-- the entry is itself a link, and a link inside a link is invalid HTML.
local function unlink(inlines)
  local out = pandoc.Inlines({})
  for _, inline in ipairs(inlines) do
    if inline.t == "Link" then
      out:extend(inline.content)
    else
      out:insert(inline)
    end
  end
  return out
end

local function title_inlines(node)
  if node.name and pandoc.utils.stringify(node.name) ~= "" then
    return unlink(pandoc.utils.blocks_to_inlines(pandoc.Blocks(node.name)))
  end
  for _, block in ipairs(node.content or {}) do
    if block.t == "Header" then
      return unlink(block.content)
    end
  end
  return nil
end

-- Quarto turns a #def- div into a Theorem custom node before user filters run,
-- so match that node.
local function collect(node)
  local id = node.identifier or ""
  if not id:match("^def%-") then return end
  table.insert(entries, { id = id, title = title_inlines(node) })
end

function Pandoc(doc)
  local enabled = doc.meta["def-list"]
  if not enabled or pandoc.utils.stringify(enabled) ~= "true" then
    return nil
  end
  if #entries == 0 then return nil end
  local heading = doc.meta["def-list-title"]
      and pandoc.utils.stringify(doc.meta["def-list-title"])
      or "Definitions on this page"
  local items = {}
  for _, e in ipairs(entries) do
    local text = pandoc.Inlines({ label_cite(e.id) })
    if e.title then
      text:insert(pandoc.Str(" ("))
      text:extend(e.title)
      text:insert(pandoc.Str(")"))
    end
    local link = pandoc.Link(text, "#" .. e.id)
    table.insert(items, { pandoc.Plain({ link }) })
  end
  -- A top-level heading, so the list is not nested inside the last section.
  -- Before an explicit "# References" + #refs pair, so the References stay last,
  -- as they do when citeproc appends them itself. Any other layout appends at
  -- the end: a new level-1 section placed before a deeper heading, or before a
  -- #refs block with no heading, would swallow the blocks that follow it.
  local at = #doc.blocks + 1
  for i, block in ipairs(doc.blocks) do
    if block.t == "Div" and block.identifier == "refs" then
      local prev = doc.blocks[i - 1]
      if prev and prev.t == "Header" and prev.level == 1 then
        at = i - 1
      end
      break
    end
  end
  doc.blocks:insert(at, pandoc.Header(1, heading,
    pandoc.Attr("def-list-section", { "unnumbered" })))
  doc.blocks:insert(at + 1, pandoc.BulletList(items))
  return doc
end

-- Top-down, so a definition nested in another follows it, as on the page.
return { { traverse = "topdown", Theorem = collect }, { Pandoc = Pandoc } }
