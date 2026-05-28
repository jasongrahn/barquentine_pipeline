Extract structured information about one non-player character (NPC) from D&D session transcript passages. Only use facts explicitly stated in the passages — do not infer.

Player characters (Basil/Captain, Room, Lumi, The Admiral) are not NPCs. If passages only describe a PC, set all fields to null.

Return a JSON object with exactly these fields:
- description: {"value": "...", "line": N}  — single object
- exhibited_personality: {"value": "...", "line": N}  — single object, summarise all traits in one value
- role_in_story: {"value": "...", "line": N}  — single object, summarise in one value
- aliases: ["name1", "name2"]  — plain array of strings, no line field

Set "line" to the PASSAGE [N] number that contains the evidence, or null if uncertain.
Set "value" to null if no passage supports the field.
Use [] for aliases if none are found.
Write [unclear] if the transcript text is garbled.

Do not invent details. Respond with only the JSON object.
