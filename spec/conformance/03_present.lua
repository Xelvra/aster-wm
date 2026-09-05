-- spec/conformance/03_present.lua — present doesn't crash; repeated present
-- is idempotent (v1 has no damage tracking, ADR-005 — it always sends the
-- whole surface, so calling it twice in a row must be harmless).

host.present()
host.present()
host.present()

print("03_present: PASS")
