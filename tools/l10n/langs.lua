--[[
The languages Ink Away ships, as KOReader names them: the code is the file name in
ink/l10n/ and the language folder in KOReader's own l10n. `name` is for the header of
the file, `plural` its Plural-Forms line (Ink Away has no plural messages, but
translation editors expect the line).
]]

return {
    { code = "de", name = "German", plural = "nplurals=2; plural=(n != 1);" },
    { code = "el", name = "Greek", plural = "nplurals=2; plural=(n != 1);" },
    { code = "es", name = "Spanish", plural = "nplurals=2; plural=(n != 1);" },
    { code = "fr", name = "French", plural = "nplurals=2; plural=(n > 1);" },
    { code = "it_IT", name = "Italian", plural = "nplurals=2; plural=(n != 1);" },
    { code = "pl", name = "Polish", plural = "nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);" },
    { code = "pt_BR", name = "Brazilian Portuguese", plural = "nplurals=2; plural=(n > 1);" },
    { code = "pt_PT", name = "Portuguese", plural = "nplurals=2; plural=(n != 1);" },
    { code = "ru", name = "Russian", plural = "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);" },
    { code = "tr", name = "Turkish", plural = "nplurals=2; plural=(n > 1);" },
}
