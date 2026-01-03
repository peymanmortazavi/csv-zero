#ifndef CSVZERO_H
#define CSVZERO_H

#include <stdlib.h>

typedef struct csvz_iterator csvz_iterator;
typedef enum {
  CSVZ_NO_ERROR,
  CSVZ_OOM,
  CSVZ_FIELD_TOO_LONG,
  CSVZ_EOF,
  CSVZ_INVALID_QUOTES,
  CSVZ_READ_FAILED,
  CSVZ_OPEN_ERROR,
} csvz_error;
typedef struct {
  char *data;
  size_t len;
  char last_column;
  char needs_unescape;
} csvz_field;

extern csvz_iterator *csvz_iter_from_file(const char *filename, char *buffer,
                                          size_t len);
extern void csvz_iter_free(csvz_iterator *);
extern csvz_error csvz_iter_next(csvz_iterator *, csvz_field *);
extern csvz_error csvz_err();
extern ulong csvz_iter_count(csvz_iterator *);

#endif
