#ifndef CSVZERO_H
#define CSVZERO_H

#include <stdio.h>
#include <stdlib.h>

/**
 * @file csvzero.h
 * @brief Zero-copy CSV parser with streaming support
 *
 * This library provides efficient CSV parsing with minimal memory allocation.
 * It uses a zero-copy approach where field data points into the parser's
 * buffer rather than allocating new memory for each field.
 */

/**
 * @brief Opaque CSV iterator structure
 *
 * Maintains the state of CSV parsing. Create with csvz_iter_from_*() functions
 * and free with csvz_iter_free().
 */
typedef struct csvz_iterator csvz_iterator;

/**
 * @brief Error codes returned by CSV parsing operations
 */
typedef enum {
  CSVZ_OK,                 /**< Operation succeeded */
  CSVZ_ERR_OOM,            /**< Out of memory */
  CSVZ_ERR_FIELD_TOO_LONG, /**< Field exceeds buffer size */
  CSVZ_ERR_EOF,            /**< End of file reached */
  CSVZ_ERR_INVALID_QUOTES, /**< Malformed quoted field */
  CSVZ_ERR_READ_FAILED,    /**< I/O read operation failed */
  CSVZ_ERR_OPEN_ERROR,     /**< Failed to open file */
} csvz_error;

/**
 * @brief Represents a single CSV field
 *
 * The data pointer points into the parser's internal buffer and is NOT
 * null-terminated. Use the len field to determine the field's size.
 */
typedef struct {
  char *data;         /**< Pointer to field data (NOT null-terminated) */
  size_t len;         /**< Length of field in bytes */
  int last_column;    /**< 1 if this is the last column in the row */
  int needs_unescape; /**< 1 if field contains escaped quotes ("") */
} csvz_field;

/**
 * @brief Status codes for custom read callbacks
 */
typedef enum {
  CSVZ_READ_STATUS_OK,    /**< Read succeeded */
  CSVZ_READ_STATUS_EOF,   /**< End of input reached */
  CSVZ_READ_STATUS_ERROR, /**< Read error occurred */
} csvz_read_status;

/**
 * @brief Return type for custom read callback functions
 */
typedef struct {
  size_t bytes_read;       /**< Number of bytes successfully read */
  csvz_read_status status; /**< Status of the read operation */
} csvz_read_result;

/**
 * @brief Create a CSV iterator that reads from a file
 *
 * Opens and reads from the specified file. The iterator takes ownership
 * of the file handle and will close it when freed.
 *
 * @param filename Path to the CSV file
 * @param buffer User-provided buffer for parsing (must remain valid for
 *               the iterator's lifetime)
 * @param len Size of the buffer in bytes
 * @return Pointer to iterator, or NULL on error (call csvz_err() for details)
 *
 * @note The buffer must be large enough to hold the longest field in the CSV.
 *       Recommended size is at least 4KB.
 */
csvz_iterator *csvz_iter_from_file(const char *filename, char *buffer,
                                   size_t len);

/**
 * @brief Create a CSV iterator that reads from an open FILE*
 *
 * The FILE* must remain valid and open for the lifetime of the iterator.
 * The caller is responsible for closing the FILE* after freeing the iterator.
 *
 * @param fd Open file descriptor
 * @param buffer User-provided buffer for parsing (must remain valid for
 *               the iterator's lifetime)
 * @param len Size of the buffer in bytes
 * @return Pointer to iterator, or NULL on error (call csvz_err() for details)
 */
csvz_iterator *csvz_iter_from_fd(FILE *fd, char *buffer, size_t len);

/**
 * @brief Create a CSV iterator that parses from an in-memory byte array
 *
 * Operates directly on the provided data with zero-copy. No internal buffer
 * is allocated.
 *
 * @param data Pointer to CSV data in memory (must remain valid for the
 *             iterator's lifetime)
 * @param len Size of the data in bytes
 * @return Pointer to iterator, or NULL on error (call csvz_err() for details)
 *
 * @note No buffer parameter is needed as this operates directly on the data.
 */
csvz_iterator *csvz_iter_from_bytes(char *data, size_t len);

/**
 * @brief Create a CSV iterator that reads data via a custom callback
 *
 * Allows integration with custom I/O sources. The callback is invoked
 * when the parser needs more data.
 *
 * @param context User-provided context pointer passed to the callback
 * @param read Callback function that reads data into the provided buffer.
 *             Should return csvz_read_result with bytes_read and status.
 *             Signature: csvz_read_result read(void *context, char *buffer,
 *                                              size_t len)
 * @param buffer User-provided buffer for parsing (must remain valid for
 *               the iterator's lifetime)
 * @param len Size of the buffer in bytes
 * @return Pointer to iterator, or NULL on error (call csvz_err() for details)
 *
 * @note The callback should fill the buffer with up to len bytes and return
 *       the number of bytes actually read along with the appropriate status.
 */
csvz_iterator *csvz_iter_from_callback(void *context,
                                       csvz_read_result (*read)(void *context,
                                                                char *buffer,
                                                                size_t len),
                                       char *buffer, size_t len);

/**
 * @brief Free a CSV iterator and release its resources
 *
 * If the iterator was created with csvz_iter_from_file(), this will close
 * the underlying file. For other iterator types, only the iterator structure
 * is freed.
 *
 * @param iter Iterator to free (can be NULL, in which case this is a no-op)
 */
void csvz_iter_free(csvz_iterator *iter);

/**
 * @brief Unescape CSV quoted field data in-place
 *
 * Converts escaped quotes ("") to single quotes ("). Should be called when
 * csvz_field.needs_unescape is 1.
 *
 * @param data Pointer to field data (will be modified in-place)
 * @param len Length of the field data
 * @return New length after unescaping (always <= original len)
 *
 * @note This modifies the data in-place, so the original buffer is altered.
 *
 * Example usage:
 *
 *   csvz_field field;
 *   if (csvz_iter_next(iter, &field) == CSVZ_OK) {
 *     if (field.needs_unescape) {
 *       field.len = csvz_unescape_in_place(field.data, field.len);
 *     }
 *     // Now field.data contains unescaped data
 *   }
 */
size_t csvz_unescape_in_place(char *data, size_t len);

/**
 * @brief Parse the next CSV field from the iterator
 *
 * Advances the iterator to the next field and populates the provided
 * csvz_field structure. Fields are returned in row-major order (all fields
 * in row 1, then all fields in row 2, etc.).
 *
 * @param iter CSV iterator
 * @param field Pointer to csvz_field structure to populate
 * @return CSVZ_OK on success
 *         CSVZ_ERR_EOF when end of input is reached
 *         Other CSVZ_ERR_* codes on error
 *
 * @note The field->data pointer is only valid until the next call to
 *       csvz_iter_next() or csvz_iter_free().
 * @note Check field->last_column to detect end of row.
 * @note Check field->needs_unescape and call csvz_unescape_in_place() if
 *       needed.
 *
 * Example usage:
 *
 *   csvz_field field;
 *   while (csvz_iter_next(iter, &field) == CSVZ_OK) {
 *     if (field.needs_unescape) {
 *       field.len = csvz_unescape_in_place(field.data, field.len);
 *     }
 *     printf("Field: %.*s\n", (int)field.len, field.data);
 *     if (field.last_column) {
 *       printf("End of row\n");
 *     }
 *   }
 */
csvz_error csvz_iter_next(csvz_iterator *iter, csvz_field *field);

/**
 * @brief Get the last error code
 *
 * Returns the error code from the most recent operation that failed.
 * Useful when iterator creation functions return NULL to determine
 * the cause of failure.
 *
 * @return The last error code
 *
 * Example usage:
 *
 *   csvz_iterator *iter = csvz_iter_from_file("data.csv", buffer,
 *                                              sizeof(buffer));
 *   if (!iter) {
 *     csvz_error err = csvz_err();
 *     if (err == CSVZ_ERR_OPEN_ERROR) {
 *       fprintf(stderr, "Failed to open file\n");
 *     }
 *   }
 */
csvz_error csvz_err();

#endif
