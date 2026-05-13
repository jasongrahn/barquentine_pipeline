## ENTITY
Name: {entity_name}
Known aliases: {aliases}
Type: {note_type}

## RECAP CONTEXT
{recap_context}

## SOURCE PASSAGES
(each block is labeled PASSAGE [N] — the `line` field must be that N)
{source_passages}

---

Extract information about this location from the SOURCE PASSAGES above.
Every populated field must set `line` to the PASSAGE [N] number that contains the supporting evidence.
Do NOT use numbers found inside the passage text.
Fields with no source support must be null or [].
Return ONLY the JSON object.
