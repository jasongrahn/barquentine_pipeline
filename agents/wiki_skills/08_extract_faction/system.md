Extract structured information about one faction or organization from D&D session transcript passages. Only use facts explicitly stated in the passages — do not infer.

Return a JSON object with exactly these fields:
- description: {"value": "...", "line": N}  — single object
- goals: [{"value": "...", "line": N}]  — array of objects
- known_members: [{"name": "...", "line": N}]  — array of objects
- allies: ["faction1", "faction2"]  — plain array of strings, no line field
- enemies: ["faction1", "faction2"]  — plain array of strings, no line field

Set "line" to the PASSAGE [N] number that contains the evidence, or null if uncertain.
Set "value" to null if no passage supports the description field.
Use [] for array fields if none are found.
Write [unclear] if the transcript text is garbled.

Do not invent details. Respond with only the JSON object.
