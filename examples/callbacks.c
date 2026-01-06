#include "../include/csvzero.h"
#include <stdio.h>

typedef struct {
  FILE *fd;
  size_t read_count;
  int error_number;
} Context;

csvz_read_result read(void *context, char *buffer, size_t len) {
  csvz_read_result result;
  Context *ctx = (Context *)context;
  ctx->read_count++;
  result.bytes_read = fread(buffer, sizeof(char), len, ctx->fd);
  if (result.bytes_read) {
    result.status = CSVZ_READ_STATUS_OK;
  } else {
    if (feof(ctx->fd)) {
      result.status = CSVZ_READ_STATUS_EOF;
    } else {
      result.status = CSVZ_READ_STATUS_ERROR;
      ctx->error_number = ferror(ctx->fd);
    }
  }

  return result;
}

int main(int argc, const char *argv[]) {
  if (argc < 2) {
    printf("missing filename\n");
    return 1;
  }

  char buffer[64];
  Context ctx;
  ctx.read_count = 0;
  ctx.error_number = 0;
  ctx.fd = fopen(argv[1], "rb");
  if (!ctx.fd) {
    perror("failed to open file\n");
    return 1;
  }
  csvz_iterator *it =
      csvz_iter_from_callback(&ctx, read, buffer, sizeof(buffer));
  if (!it) {
    printf("err %d encountered creating it\n", csvz_err());
    return 1;
  }
  csvz_field field;
  csvz_error err;

  size_t row = 0, col = 0;
  while ((err = csvz_iter_next(it, &field)) == CSVZ_OK) {
    if (field.needs_unescape) {
      field.len = csvz_unescape_in_place(field.data, field.len);
    }

    printf("field[%zu][%zu] = |%.*s|\n", row, col, (int)field.len, field.data);
    if (field.last_column) {
      row++;
      col = 0;
    } else {
      col++;
    }
  }

  switch (err) {
  case CSVZ_ERR_FIELD_TOO_LONG:
    printf("> field too long at row=%zu, col=%zu\n", row, col);
    break;
  case CSVZ_ERR_INVALID_QUOTES:
    printf("invalid quotes at row=%zu, col=%zu\n", row, col);
  case CSVZ_ERR_EOF:
    break;
  default:
    printf("err %d encountered at row=%zu, col=%zu\n", err, row, col);
  }
}
