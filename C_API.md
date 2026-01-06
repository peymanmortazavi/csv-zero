# csv-zero C API Reference

This document covers the C API for csv-zero, a high-performance, zero-copy and streaming CSV parser.

## Quick Start

Here's a minimal example to parse a CSV file:

```c
#include "csvzero.h"
#include <stdio.h>

int main(void) {
    char buffer[64 * 1024];  // 64KB buffer for parsing

    csvz_iterator *iter = csvz_iter_from_file("data.csv", buffer, sizeof(buffer));
    if (!iter) {
        fprintf(stderr, "Failed to open file: error %d\n", csvz_err());
        return 1;
    }

    csvz_field field;
    while (csvz_iter_next(iter, &field) == CSVZ_OK) {
        if (field.needs_unescape) {
            field.len = csvz_unescape_in_place(field.data, field.len);
        }
        // NOTE: data is NOT null-terminated, use %.*s
        printf("field: %.*s", (int)field.len, field.data);
    }

    csvz_iter_free(iter);
    return 0;
}
```

## Buffer Size Recommendations

The buffer you provide must be large enough to hold the **longest field** in your CSV file:

- **Minimum:** 4 KB (4096 bytes) for typical CSV files
- **Recommended:** 64 KB (65536 bytes) for general use
- **Large fields:** 256K if you have very large text fields

If a field exceeds the buffer size, `csvz_iter_next()` will return `CSVZ_ERR_FIELD_TOO_LONG`.

## Creating Iterators

csv-zero supports four different input sources. Choose the one that fits your use case.

### 1. From a File Path

The simplest approach - provide a filename and let csv-zero handle the file:

```c
char buffer[64 * 1024];
csvz_iterator *iter = csvz_iter_from_file("data.csv", buffer, sizeof(buffer));

if (!iter) {
    csvz_error err = csvz_err();
    if (err == CSVZ_ERR_OPEN_ERROR) {
        fprintf(stderr, "Could not open file\n");
    }
    return 1;
}

// Use iterator...

csvz_iter_free(iter);  // closes the file
```

**Notes:**

- The iterator takes ownership of the file handle
- `csvz_iter_free()` will close the file
- Use `csvz_err()` to get the error code if creation fails

### 2. From an Open FILE\*

If you already have an open `FILE*`, you can use it directly:

```c
FILE *fp = fopen("data.csv", "r");
if (!fp) {
    perror("fopen");
    return 1;
}

char buffer[64 * 1024];
csvz_iterator *iter = csvz_iter_from_fd(fp, buffer, sizeof(buffer));

if (!iter) {
    fprintf(stderr, "Failed to create iterator: error %d\n", csvz_err());
    fclose(fp);
    return 1;
}

// Use iterator...

csvz_iter_free(iter);
fclose(fp);  // YOU must close the FILE* yourself
```

**Important:**

- The `FILE*` must remain open for the iterator's entire lifetime
- You are responsible for closing the `FILE*` after freeing the iterator
- Do NOT close the file while the iterator is still in use

### 3. From Memory

Parse CSV data that's already in memory:

```c
const char *csv_data = "name,age\nPancake,30\nPookie,25\n";
size_t data_len = strlen(csv_data);

// NOTE: Cast away const if your data is read-only but you know you will not unescape in place.
// If you use csvz_unescape_in_place(), it will overwrite the buffer.
csvz_iterator *iter = csvz_iter_from_bytes((char *)csv_data, data_len);

if (!iter) {
    fprintf(stderr, "Failed to create iterator: error %d\n", csvz_err());
    return 1;
}

csvz_field field;
while (csvz_iter_next(iter, &field) == CSVZ_OK) {
    // Process field...
}

csvz_iter_free(iter);
```

**Important:**

- No buffer parameter needed - operates directly on your data
- The data pointer must remain valid for the iterator's lifetime
- Field pointers will point directly into your data array
- If you call `csvz_unescape_in_place()`, it will modify your data array

### 4. From a Custom Callback

For custom I/O sources (network streams, compressed files, etc.):

```c
typedef struct {
  FILE *fd;
  int read_err;
} Context;

csvz_read_result read(void *data, char *buffer, size_t len) {
  Context *context = (Context *)data;
  csvz_read_result result;
  result.bytes_read = fread(buffer, sizeof(char), len, context->fd);
  if (result.bytes_read == 0) {
    if (feof(context->fd)) {
      result.status = CSVZ_READ_STATUS_EOF;
    } else {
      context->read_err = ferror(context->fd); // preserve the error to examine later.
      result.status = CSVZ_READ_STATUS_ERROR;
    }
  } else {
    result.status = CSVZ_READ_STATUS_OK;
  }
  return result;
}

int main(void) {
    char buffer[64 * 1024];
    Context ctx;
    ctx.fd = fopen("data.csv", "rb");
    ctx.read_err = 0;

    csvz_iterator *iter = csvz_iter_from_callback(&ctx, read, buffer, sizeof(buffer));

    // Use iterator...

    csvz_iter_free(iter);
    fclose(ctx.fd);
    return 0;
}
```

## Iterating Over Fields

The core parsing operation is `csvz_iter_next()`:

```c
csvz_field field;
csvz_error err;

while ((err = csvz_iter_next(iter, &field)) == CSVZ_OK) {
    // NOTE: if your file might have escape chars, make sure you check for it.
    if (field.needs_unescape) {
        // either copy the content before unescaping or overwrite the buffer in place.
        field.len = csvz_unescape_in_place(field.data, field.len);
    }
    printf("Field: %.*s\n", (int)field.len, field.data);

    // Check if this is the last column in the row
    if (field.last_column) {
        printf("--- End of row ---\n");
    }
}

if (err != CSVZ_ERR_EOF) {
    fprintf(stderr, "Error during parsing: %d\n", err);
}
```

### Field Structure

```c
typedef struct {
    char *data;         // Pointer to field data (NOT null-terminated!)
    size_t len;         // Length of field in bytes
    int last_column;    // 1 if last column in row, 0 otherwise
    int needs_unescape; // 1 if field contains escaped quotes ("")
} csvz_field;
```

**Critical:** `field.data` is **NOT null-terminated**. Always use `field.len` and `%.*s` format specifier:

```c
// CORRECT:
printf("%.*s", (int)field.len, field.data);

// WRONG - may read past end of field:
printf("%s", field.data);
```

## Handling Escaped Quotes

CSV fields can contain escaped quotes (`""`). Check `field.needs_unescape` and handle accordingly:

```c
csvz_field field;
while (csvz_iter_next(iter, &field) == CSVZ_OK) {
    if (field.needs_unescape) {
        // Unescape in-place - modifies the buffer!
        field.len = csvz_unescape_in_place(field.data, field.len);
    }

    // Now field.data contains unescaped data
    printf("%.*s\n", (int)field.len, field.data);
}
```

**Important:**

- `csvz_unescape_in_place()` modifies the buffer in-place
- After unescaping, `field.len` may be shorter (but never longer)
- For `csvz_iter_from_bytes()`, this will modify your original data array if you use `csvz_unescape_in_place` on the
  buffer data (aka `field.data`).

## Error Handling

All functions that can fail either return an error code or `NULL` with an error code available via `csvz_err()`:
The ones that return an error will **NOT** update the thread local error code thus `csvz_err()` will not get updated.

```c
// Iterator creation functions return NULL on error
csvz_iterator *iter = csvz_iter_from_file("data.csv", buffer, sizeof(buffer));
if (!iter) {
    csvz_error err = csvz_err();
    switch (err) {
        case CSVZ_ERR_OPEN_ERROR:
            fprintf(stderr, "Could not open file\n");
            break;
        case CSVZ_ERR_OOM:
            // other than a calloc to return csvz_iterator, no other heap allocation is done by this library.
            // thus OOM is very unlikely.
            fprintf(stderr, "Out of memory! This is so very unlikely\n");
            break;
        default:
            fprintf(stderr, "Unknown error: %d\n", err);
    }
    return 1;
}

// csvz_iter_next returns error code directly
csvz_field field;
csvz_error err;
while ((err = csvz_iter_next(iter, &field)) == CSVZ_OK) {
    // Process field
}

if (err != CSVZ_ERR_EOF) {
    switch (err) {
        case CSVZ_ERR_FIELD_TOO_LONG:
            fprintf(stderr, "Field exceeds buffer size - increase buffer\n");
            break;
        case CSVZ_ERR_INVALID_QUOTES:
            fprintf(stderr, "Malformed CSV - invalid quote escaping\n");
            break;
        case CSVZ_ERR_READ_FAILED:
            fprintf(stderr, "I/O error during read\n");
            break;
        default:
            fprintf(stderr, "Parse error: %d\n", err);
    }
}

csvz_iter_free(iter);
```

### Error Codes

```c
typedef enum {
    CSVZ_OK,                  // Success
    CSVZ_ERR_OOM,             // Out of memory
    CSVZ_ERR_FIELD_TOO_LONG,  // Field exceeds buffer size
    CSVZ_ERR_EOF,             // End of file (normal termination)
    CSVZ_ERR_INVALID_QUOTES,  // Malformed quoted field
    CSVZ_ERR_READ_FAILED,     // I/O read error
    CSVZ_ERR_OPEN_ERROR,      // Failed to open file
} csvz_error;
```

## Complete Example: Processing Rows

Here's a complete example that processes CSV data row by row:

```c
#include "csvzero.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    char buffer[64 * 1024];

    csvz_iterator *iter = csvz_iter_from_file("employees.csv",
                                               buffer, sizeof(buffer));
    if (!iter) {
        fprintf(stderr, "Failed to open file: %d\n", csvz_err());
        return 1;
    }

    csvz_field field;
    csvz_error err;
    size_t row = 0, col = 0;

    while ((err = csvz_iter_next(iter, &field)) == CSVZ_OK) {
        // Unescape if needed
        if (field.needs_unescape) {
            field.len = csvz_unescape_in_place(field.data, field.len);
        }

        // Print field
        printf("field[%zu][%zu] = '%.*s'\n", row, col, (int)field.len, field.data);

        if (field.last_column) {
            printf("--\n");
            row++;
            col = 0;
        } else {
            col++;
        }
    }

    printf("\n");
    if (err == CSVZ_ERR_EOF) {
        printf("Parsed %zu rows successfully\n", row);
    } else {
        fprintf(stderr, "Error at row %zu, column %zu: %d\n", row, col, err);
    }

    csvz_iter_free(iter);
    return 0;
}
```

## Important Notes

### Memory and Lifetime

1. **Field data is temporary:** `field.data` pointers are only valid until the next call to `csvz_iter_next()` or `csvz_iter_free()`

2. **Copy data if you need to keep it:**

   ```c
   char *saved_field = malloc(field.len + 1);
   memcpy(saved_field, field.data, field.len);
   saved_field[field.len] = '\0';  // Null-terminate if needed
   ```

3. **Buffer must outlive iterator:** The buffer you pass must remain valid for the iterator's entire lifetime

4. **No null terminators:** Field data is **never** null-terminated - always use `field.len`

### Thread Safety

- **Error codes are thread-local:** Each thread has its own `csvz_err()` state
- **Iterators are NOT thread-safe:** Do not share an iterator between threads
- **Multiple iterators are safe:** You can create multiple iterators in the same or different threads

### Performance Tips

1. **Use larger buffers:** 64KB is recommended for general use, but larger is better for files with large fields

2. **Avoid unnecessary unescaping:** Only call `csvz_unescape_in_place()` if `field.needs_unescape` is 1

### Limitations

1. **Fields must fit in buffer:** If a single field exceeds the buffer size, parsing will fail with `CSVZ_ERR_FIELD_TOO_LONG`

2. **Strict RFC 4180 compliance:** Unquoted fields containing `"` will cause `CSVZ_ERR_INVALID_QUOTES`

3. **No record abstraction:** The API is field-based by design - you must track rows yourself using `field.last_column`

## Compilation

Link with the csv-zero library:

```bash
# Example with gcc (if not installed in the system library search paths)
gcc -o myprogram myprogram.c -I/path/to/csv-zero/include -L/path/to/csv-zero/lib -lcsvzero
```

## Further Reading

- [Main README](README.md) - Overview and Zig API documentation
- [include/csvzero.h](include/csvzero.h) - Complete C API header with detailed comments
- [csv-race](https://github.com/peymanmortazavi/csv-race) - Performance benchmarks
