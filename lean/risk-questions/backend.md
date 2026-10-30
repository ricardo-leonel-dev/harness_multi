# Risk questions: backend / API with a database

Every feature document answers these before any code is written.

1. **Access**: who may read, and who may change, what this feature touches? What does everyone else get?
2. **Concurrency**: what happens when two requests do this at the same time?
3. **Existing data**: what happens to the rows (and clients) that exist before this change?
4. **Invalid input**: which bad inputs must be a 4xx, never a 500?
5. **Scope**: what does this feature leave out on purpose?
