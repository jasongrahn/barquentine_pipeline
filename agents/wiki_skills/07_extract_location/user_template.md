Entity: {entity_name}
Known aliases: {aliases}
Type: {note_type}

Context: {recap_context}

{existing_note_block}
Target entity: {entity_name} (type: {note_type}). Focus exclusively on this entity. All other characters mentioned in the passages are context, not the subject.

SOURCE PASSAGES
(each block labeled PASSAGE [N] — use N as the line number)
{source_passages}

---

If an EXISTING NOTE was provided above, copy its field values into your JSON output as the starting point. Then update using the SOURCE PASSAGES: add new details the passages reveal, and note contradictions.
If no EXISTING NOTE was provided, extract only from SOURCE PASSAGES.
Fields with no support from either source must be null or [].
Do not explain why a field is empty — just return null or [].

Target entity: {entity_name} (type: {note_type}). Focus exclusively on this entity. All other characters mentioned in the passages are context, not the subject.
