#ifndef CSVZERO_H
#define CSVZERO_H

#include <stdio.h>
#include <stdlib.h>

typedef struct csvz_iterator csvz_iterator;

typedef enum {
  CSVZ_OK,
  CSVZ_ERR_OOM,
  CSVZ_ERR_FIELD_TOO_LONG,
  CSVZ_ERR_EOF,
  CSVZ_ERR_INVALID_QUOTES,
  CSVZ_ERR_READ_FAILED,
  CSVZ_ERR_OPEN_ERROR,
} csvz_error;

typedef struct {
  char *data;
  size_t len;
  int last_column;
  int needs_unescape;
} csvz_field;

typedef enum {
  CSVZ_READ_STATUS_OK,
  CSVZ_READ_STATUS_EOF,
  CSVZ_READ_STATUS_ERROR,
} csvz_read_status;

typedef struct {
  size_t bytes_read;
  csvz_read_status status;
} csvz_read_result;

csvz_iterator *csvz_iter_from_file(const char *filename, char *buffer,
                                   size_t len);
csvz_iterator *csvz_iter_from_fd(FILE *fd, char *buffer, size_t len);
csvz_iterator *csvz_iter_from_bytes(char *data, size_t len);
csvz_iterator *csvz_iter_from_callback(void *context,
                                       csvz_read_result (*read)(void *, char *,
                                                                size_t),
                                       char *buffer, size_t len);
void csvz_iter_free(csvz_iterator *);
size_t csvz_unescape_in_place(char *data, size_t len);
csvz_error csvz_iter_next(csvz_iterator *, csvz_field *);
csvz_error csvz_err();

#endif
