-- GarchaDex / Locale.lua
-- The client's language decides the UI text. Spanish is what the code writes; this file
-- translates it when the client is not Spanish. A key-based rewrite is the eventual goal;
-- this phrase table exists so every screen is localized without touching call sites.
--
-- Only plain strings pass through ns.T. Secret values (the enemy's spell name, its icon)
-- are NEVER text: they go straight to the widget, so they are never translated nor read.

local addonName, ns = ...

local locale = (type(GetLocale) == "function" and GetLocale()) or "enUS"
ns.LOCALE = locale
ns.IS_SPANISH = (string.sub(locale, 1, 2) == "es")
-- Active language: the client's own by default, overridable with /gdx lang es|en|auto and
-- remembered in the saved variables.
ns.LANG = ns.IS_SPANISH and "es" or "en"
ns.DEFAULT_LANG = ns.LANG
function ns.SetLang(code)
	if code == "auto" or code == nil then
		ns.LANG = ns.DEFAULT_LANG
	elseif code == "es" or code == "en" then
		ns.LANG = code
	end
	return ns.LANG
end

-- Spanish phrase -> English. Longer phrases are applied first so they win over their parts.
local DICT = {
	["buscar por nombre (seed):"] = "search by name (seed):",
	["la referencia tiene"] = "the reference has",
	["items en la pool, pero su contenido no se empaqueta"] = "items in the pool, but its contents are not bundled",
	["para mobs comunes: esta lista se llena con lo que lootees vos."] = "for common mobs: this list fills up with what you loot yourself.",
	["este mob no aparece en la base 1.12"] = "this mob is not in the 1.12 database",
	["sin entrada en el seed: contenido de Forever, o mob que la base 1.12 no tiene"] = "no seed entry: Forever content, or a mob the 1.12 database does not have",
	["MOB COMUN: sin ficha en el seed, pero la referencia tiene"] = "COMMON MOB: no seed entry, but the reference has",
	["items y"] = "items and",
	["hechizo(s)"] = "spell(s)",
	["MEDIDO: visto"] = "MEASURED: seen",
	["veces · kills"] = "times · kills",
	["looteado"] = "looted",
	["plata"] = "money",
	["muertes (atribuidas al mob que peleabas)"] = "deaths (credited to the mob you were fighting)",
	["REFERENCIA 1.12: lvl"] = "REFERENCE 1.12: lvl",
	["MEDIDO = lo que looteaste vos. REFERENCIA = base 1.12, no medida en Forever."] = "MEASURED = what you looted yourself. REFERENCE = 1.12 base, not measured in Forever.",
	["HECHIZOS (referencia 1.12)"] = "SPELLS (1.12 reference)",
	["(referencia 1.12, id"] = "(1.12 reference, id",
	["OBSERVADO:"] = "OBSERVED:",
	["casteos (el cliente oculta la identidad para addons)"] = "casts (the client hides the identity from addons)",
	["casteo observado"] = "observed cast",
	["sin dato"] = "no data",
	["DROPS MEDIDOS"] = "MEASURED DROPS",
	["en looteos (N referencia:"] = "over looted corpses (reference N:",
	["sin drops medidos"] = "no drops measured yet",
	["REFERENCIA VANILLA 1.12"] = "VANILLA 1.12 REFERENCE",
	["items en la pool):"] = "items in the pool):",
	["condicional de quest"] = "quest-conditional",
	["grupo compartido"] = "shared group",
	["HECHIZOS OBSERVADOS"] = "OBSERVED SPELLS",
	["con nombre legible"] = "with a readable name",
	["(el cliente oculta el id para addons)"] = "(the client hides the id from addons)",
	["(secreto: el nombre y el icono se dibujan en la ventana: /gdx)"] = "(secret: the name and icon are drawn in the window: /gdx)",
	["sin nombre"] = "no name",
	["secreto"] = "secret",
	["y mas"] = "and more",
	["sin ficha en el seed"] = "no seed entry",
	["targeteá un enemigo o pasá un npc id. Comandos:"] = "target an enemy or pass an npc id. Commands:",
	["ficha del target (ventana)"] = "target's card (window)",
	["ficha por id"] = "card by id",
	["la ficha en texto copiable"] = "the card as copyable text",
	["en el chat"] = "in chat",
	["estado del seed"] = "seed status",
	["borra lo capturado del target"] = "wipes what was captured for the target",
	["contadores"] = "counters",
	["render de valores secretos"] = "secret value render test",
	["texto en la ventana: seleccionado, Cmd+C para copiar."] = "text in the window: selected, Cmd+C to copy.",
	["targeteá un enemigo para copiar su ficha (o usá /gdx text <npcID>)"] = "target an enemy to copy its card (or use /gdx text <npcID>)",
	["targeteá un enemigo, o usá"] = "target an enemy, or use",
	["borre los datos capturados del npc"] = "wiped captured data for npc",
	["(la referencia del seed queda)"] = "(the seed reference stays)",
	["borre TODOS los datos capturados. La referencia y el rastro por personaje quedan."] = "wiped ALL captured data. The reference and the per-character trace stay.",
	["el npc"] = "npc",
	["no tenia datos capturados"] = "had no captured data",
	["nada capturado todavia"] = "nothing captured yet",
	["capturado: visto"] = "captured: seen",
	["sin drops medidos"] = "no drops measured",
	["ventana lista."] = "window ready.",
	["o targetear y"] = "or target and",
	["cargado. seed["] = "loaded. seed[",
	["capturados="] = "tracked=",
	["para ayuda."] = "for help.",
	["el seed NO se cargo: revisá que GarchaDex/data/gdx_seed.lua exista (el .toc lo lista como data\\gdx_seed.lua) y mirá si hubo un error de Lua al iniciar."] = "the seed did NOT load: check that GarchaDex/data/gdx_seed.lua exists (the .toc lists it as data\\gdx_seed.lua) and look for a Lua error at login.",
	["version"] = "version",
	["tablas:"] = "tables:",
	["AUSENTE"] = "MISSING",
	["chequeo crudo:"] = "raw check:",
	["mobs registrados"] = "mobs tracked",
	["de este personaje:"] = "for this character:",
	["looteos"] = "loot windows",
	["nodos"] = "nodes",
	["loot no atribuido:"] = "unattributed loot:",
	["ultimo source:"] = "last source:",
	["todavia nada"] = "nothing yet",
	["de esos, atribuidos por ultimo-kill (fallback):"] = "of those, credited by last-kill (fallback):",
	["test de render ->"] = "render test ->",
	["Decime si en la ventana ves el nombre del hechizo y el icono de verdad (no un cuadro con '?')."] = "Tell me if the window shows the spell name and the real icon (not a '?' box).",
	["sigue secreto (sin dedupe, como esperaba)"] = "stays secret (no dedupe, as expected)",
	["sigue secreto"] = "stays secret",
	["se puede deduplicar!"] = "can be deduped!",
	["BLOQUEADO"] = "BLOCKED",
	["PLANO"] = "PLAIN",
	["no entendi"] = "did not understand",
	["Usá /gdx, /gdx <npcID>, /gdx text, /gdx stats, /gdx test"] = "Use /gdx, /gdx <npcID>, /gdx text, /gdx stats, /gdx test",
	["te mató"] = "killed you",
	["mob comun: sin ficha en el seed, pero la referencia si tiene la pool (N="] = "common mob: no seed entry, but the reference has the pool (N=",
	["y hechizos declarados"] = "and spells declared",
	[", zona "] = ", zone ",
	["zona "] = "zone ",
	["casteos ("] = "casts (",
	["casteo observado  ["] = "observed cast  [",
	["(usa /gdx test para ver si la ventana puede mostrar el nombre y el icono)"] = "(use /gdx test to see whether the window can show the name and the icon)",
	["HECHIZOS"] = "SPELLS",
	["REFERENCIA"] = "REFERENCE",
	["sin GUID x"] = "no GUID x",
	["sin ficha en el seed, pero la referencia si tiene la pool"] = "no seed entry, but the reference does have the pool",
	["oculta el id para addons"] = "hides the id from addons",
	["veces)"] = "times)",
	["Indice"] = "Index",
	["sin visitar"] = "not visited",
	["filtro por nombre o id · rueda del mouse para scrollear"] = "filter by name or id · mouse wheel to scroll",
	["click en el texto y Cmd+A / Cmd+C para copiar"] = "click the text and Cmd+A / Cmd+C to copy",
	["click para abrir la ficha"] = "click to open the card",
	["ficha del enemigo targeteado"] = "card for the targeted enemy",
	["todos los npcs encontrados, por id"] = "every npc found, by id",
	["ultimos looteos vistos (diagnostico)"] = "last loot events seen (diagnostic)",
	["estado del seed y chequeo crudo"] = "seed status and raw check",
	["contadores generales"] = "overall counters",
	["render de valores secretos"] = "secret value render test",
	["cambiar idioma del addon"] = "change the addon's language",
	["cerrar todas las ventanas de GarchaDex"] = "close every GarchaDex window",
	["arrastrable · click derecho oculta"] = "draggable · right click hides",
	["con datos"] = "with data",
	["click en el texto · Cmd+A / Cmd+C copia · Esc cierra"] = "click the text · Cmd+A / Cmd+C copies · Esc closes",
	["Cerrar"] = "Close",
	["versión"] = "version",
	["targetea un enemigo o pasá un npc id."] = "target an enemy or pass an npc id.",
	["buscar en el seed:"] = "search the seed:",
	["nombre del mob + Enter · o targetear y tocar Ficha"] = "mob name + Enter · or target it and press Card",
	["visto"] = "seen",
	["te mato"] = "killed you",
	["casteos"] = "casts",
	["medido: visto"] = "measured: seen",
	["veces · looteado"] = "times · looted",
	["cadaveres looteados"] = "corpses looted",
	["items de la pool descubiertos"] = "pool items discovered",
	["sin drops medidos todavia"] = "no drops measured yet",
	["el cliente oculta el id del hechizo: estos nombres los dibuja el juego, no se pueden comparar ni contar"] =
		"the client hides the spell id: the game draws these names, they cannot be compared or counted",
	["(sin hechizos declarados en la referencia)"] = "(no spells declared in the reference)",
	["mob comun: sin ficha en el seed, pero la referencia tiene N="] = "common mob: no seed entry, but the reference has N=",
	["referencia 1.12: lvl"] = "reference 1.12: lvl",
	["mapa"] = "map",
	["DROPS MEDIDOS POR VOS"] = "DROPS MEASURED BY YOU",
	["REFERENCIA 1.12 ·"] = "1.12 REFERENCE ·",
	["items en la pool"] = "items in the pool",
	["esta pool no viene con su contenido en el seed: se llena con lo que lootees"] =
		"this pool does not ship its contents in the seed: it fills up with what you loot",
	["no catalogado en 1.12"] = "not in the 1.12 database",
	["sin id resuelto"] = "id not resolved",
	["items mas en la pool"] = "more items in the pool",
	["(grupo)"] = "(group)",
	["MEDIDO = lo que looteaste vos · REFERENCIA = base 1.12, no medida en Forever"] =
		"MEASURED = what you looted yourself · REFERENCE = 1.12 base, not measured in Forever",
}

local ORDER = {}
for k in pairs(DICT) do ORDER[#ORDER + 1] = k end
table.sort(ORDER, function(a, b) return #a > #b end)

-- Translate one plain string when the client is not Spanish. Never called on secret values.
function ns.T(s)
	if ns.LANG ~= "en" or type(s) ~= "string" then return s end
	local out = s
	for i = 1, #ORDER do
		local from = ORDER[i]
		if string.find(out, from, 1, true) then
			out = string.gsub(out, from:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"), DICT[from])
		end
	end
	return out
end

-- Cache a few ids once, at load, instead of calling GetLocale every time
ns.LOCALE_ID = ns.IS_SPANISH and (locale == "esMX" and "esMX" or "esES") or "enUS"
