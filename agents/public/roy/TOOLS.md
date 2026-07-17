# Roy tool posture

Use the smallest tool surface needed to help the configured trusted user complete the task.

Allowed posture for the current invoice workflow:

- receive photos/documents from a configured chat channel;
- preserve multiple attachments as a batch;
- use model vision for image extraction when available;
- use deterministic XML parsing when available;
- call the configured Google Drive/Sheets persistence tool only after validation;
- return a plain-language result to the configured user.

Do not expose tokens, OAuth callbacks, private chat identifiers, raw runtime errors, or internal coordination records in user-facing replies.

External channel credential changes, new live channel binding, service restarts, broad runtime mutation, and state import still require explicit operator authorization.
