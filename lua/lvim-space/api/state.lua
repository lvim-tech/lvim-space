-- lvim-space.api.state: the global runtime state — a single shared, mutable table that accretes the
-- active session's identity (project / workspace / tab ids, active file), the loaded language pack and
-- the live UI window handles. It starts empty and every module reads and writes it directly; the shape
-- it takes on at runtime is documented by the LvimSpace.State class in types.lua. Runtime only, never
-- config (config lives in lvim-space.config).
--
---@module "lvim-space.api.state"

---@type LvimSpace.State
return {}
