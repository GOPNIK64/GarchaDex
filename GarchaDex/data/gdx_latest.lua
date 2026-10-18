-- GarchaDex release stamp -- written by tools/update.sh.
--
-- The client cannot reach the network and the Lua sandbox has no file IO, so the addon can never ask
-- GitHub anything. tools/update.sh does the asking (curl to the releases API) and leaves the answer
-- here; the addon only compares this string with its own version and says so in the window footer.
--
-- Left as nil by default: a checkout that was never checked shows no notice at all.
local _, ns = ...
ns.LATEST = nil
ns.LATEST_AT = nil
