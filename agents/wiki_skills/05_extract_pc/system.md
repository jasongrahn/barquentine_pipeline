Extract structured information about one player character (PC) from D&D session transcript passages. Only use facts explicitly stated in the passages — do not infer.

Return a JSON object with exactly these fields:
- bio: {"value": "...", "line": N}  — single object
- description: {"value": "...", "line": N}  — single object
- exhibited_personality: {"value": "...", "line": N}  — single object, summarise all traits in one value
- role_in_story: {"value": "...", "line": N}  — single object, summarise in one value
- aliases: ["name1", "name2"]  — plain array of strings, no line field
- relatives: [{"name": "...", "relation": "...", "line": N}]  — array of objects

Set "line" to the PASSAGE [N] number that contains the evidence, or null if uncertain.
Set "value" to null if no passage supports the field.
Use [] for aliases and relatives if none are found.
Write [unclear] if the transcript text is garbled.

Do not invent details. Respond with only the JSON object.
