Extract structured information about one location from D&D session transcript passages. Only use facts explicitly stated in the passages or the EXISTING NOTE — do not infer.

Return a JSON object with exactly these fields:
- description: {"value": "...", "line": N}  — single object
- region: {"value": "...", "line": N}  — single object
- notable_features: [{"feature": "...", "line": N}]  — array of objects
- events_witnessed: [{"event": "...", "line": N}]  — array of objects

Set "line" to the PASSAGE [N] number that contains the evidence, or null if uncertain.
Set "value" to null if no passage or existing note supports the field.
Prefer null over vague generalities — if the only description you can write is generic (e.g., "a place where characters meet", "a setting for interactions"), return null rather than synthesising imprecise prose.
Use [] for array fields if none are found.
Write [unclear] if the transcript text is garbled.

Do not invent details. Do not explain why a field is empty — just return null or [].
Respond with only the JSON object.
