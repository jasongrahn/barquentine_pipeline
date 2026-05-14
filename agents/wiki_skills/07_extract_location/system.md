Extract structured information about one location from D&D session transcript passages. Only use facts explicitly stated in the passages — do not infer.

Return a JSON object with exactly these fields:
- description: {"value": "...", "line": N}  — single object
- region: {"value": "...", "line": N}  — single object
- notable_features: [{"feature": "...", "line": N}]  — array of objects
- events_witnessed: [{"event": "...", "line": N}]  — array of objects
- connections: ["place1", "place2"]  — plain array of strings, no line field

Set "line" to the PASSAGE [N] number that contains the evidence, or null if uncertain.
Set "value" to null if no passage supports the field.
Use [] for array fields if none are found.
Write [unclear] if the transcript text is garbled.

Do not invent details. Respond with only the JSON object.
