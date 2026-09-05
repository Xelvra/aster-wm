-- spec/conformance/06_fs.lua — read/write round-trip; write creates missing
-- parent directories; remove; rename onto an existing path returns
-- nil, "exists"; every error comes from the closed set in
-- spec/host-contract.md §3.9.

local base = host.info().paths.data .. "/conformance-tmp-06"
host.remove(base) -- best-effort cleanup from a previous failed run

local path = base .. "/round-trip.txt"
local ok, err = host.write(path, "hello")
assert(ok == true, "write must create missing parent directories and succeed, got " .. tostring(err))

local data, rerr = host.read(path)
assert(data == "hello", "read must round-trip exactly what was written, got " .. tostring(data) .. " / " .. tostring(rerr))

local entries, lerr = host.list(base)
assert(entries, "list must succeed on a directory write() just created, got " .. tostring(lerr))
local found = false
for _, e in ipairs(entries) do
  if e.name == "round-trip.txt" then
    found = true
    assert(e.dir == false, "round-trip.txt must be listed as a file")
    assert(type(e.mtime) == "number" and e.mtime > 0, "mtime must be a positive number")
  end
end
assert(found, "list must include the file just written")

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

print("06_fs: PASS")
