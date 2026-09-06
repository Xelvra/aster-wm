-- spec/conformance/06_fs.lua — read/write round-trip; write creates missing
-- parent directories; remove is recursive and reports not_found on a
-- missing path; rename onto an existing path returns nil, "exists"; every
-- error comes from the closed set in spec/host-contract.md's "Errors" section.

local base = host.info().paths.data .. "/conformance-tmp-06"
host.remove(base) -- best-effort cleanup from a previous failed run

local path = base .. "/round-trip.txt"
local ok, err = host.write(path, "hello")
assert(ok == true, "write must create missing parent directories and succeed, got " .. tostring(err))

local data, rerr = host.read(path)
assert(data == "hello", "read must round-trip exactly what was written, got " .. tostring(data) .. " / " .. tostring(rerr))

local entries, lerr = host.list(base)
assert(entries, "list must succeed on a directory write() just created, got " .. tostring(lerr))
local found, first_mtime = false, nil
for _, e in ipairs(entries) do
  -- write() is documented as atomic (write to a temp file, then rename);
  -- a leftover ".tmp-<ns>" sibling would mean the swap never completed
  -- cleanly.
  assert(not e.name:find("%.tmp%-"), "a stray temp file from write()'s atomic swap was left behind: " .. e.name)
  if e.name == "round-trip.txt" then
    found = true
    first_mtime = e.mtime
    assert(e.dir == false, "round-trip.txt must be listed as a file")
    assert(type(e.mtime) == "number" and e.mtime > 0, "mtime must be a positive number")
  end
end
assert(found, "list must include the file just written")

-- mtime must never go backwards across a write, which is the entire
-- premise the external-edit watch (architecture.md "Reload preserves
-- state") is built on. Unix-second resolution means two writes in the
-- same second can share an mtime, so this checks non-decreasing, not
-- strictly increasing.
assert(host.write(path, "hello, again"))
local entries2 = assert(host.list(base))
for _, e in ipairs(entries2) do
  if e.name == "round-trip.txt" then
    assert(e.mtime >= first_mtime, "mtime must not go backwards after a second write")
  end
end

local other = base .. "/other.txt"
assert(host.write(other, "x"))
local rok, rename_err = host.rename(other, path)
assert(rok == nil and rename_err == "exists", "rename onto an existing path must return nil, 'exists'")

local closed_set = {
  not_found = true, permission = true, io = true, invalid = true,
  no_space = true, busy = true, unsupported = true, exists = true,
}
local _, missing_err = host.read(base .. "/does-not-exist.txt")
assert(missing_err == "not_found", "reading a missing file must return 'not_found'")
assert(closed_set[missing_err], "'" .. tostring(missing_err) .. "' is not in the closed error set")
assert(closed_set[rename_err], "'" .. tostring(rename_err) .. "' is not in the closed error set")

assert(host.remove(base), "remove must succeed")
local _, gone_err = host.read(path)
assert(gone_err == "not_found", "file must be gone after remove")
local _, gone_other_err = host.read(other)
assert(gone_other_err == "not_found", "remove must delete a non-empty directory recursively, not just its first entry")

local rmok, rm_missing_err = host.remove(base)
assert(rmok == nil and rm_missing_err == "not_found", "remove on an already-gone path must return nil, 'not_found', got " .. tostring(rmok) .. " / " .. tostring(rm_missing_err))
assert(closed_set[rm_missing_err], "'" .. tostring(rm_missing_err) .. "' is not in the closed error set")

print("06_fs: PASS")
