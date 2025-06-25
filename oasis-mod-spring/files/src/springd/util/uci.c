#include "uci.h"

//Function equivalent to the uci get command.
void uci_get_option(char* str, char* value) {
    struct uci_context *ctx;
    struct uci_ptr ptr;

    char* param = strdup(str);

    ctx = uci_alloc_context();

    if (param == NULL) {
        return;
    }

    if (ctx == NULL) {
        return;
    }

    if (uci_lookup_ptr(ctx, &ptr, param, true) != UCI_OK) {
        uci_perror(ctx, "uci set error");
        uci_free_context(ctx);
        return;
    }

    if (ptr.o != 0 && ptr.o->type == UCI_TYPE_STRING) {
        if (sizeof(value) <= sizeof(ptr.o->v.string)) {
            strcpy(value, ptr.o->v.string);
        }
    }

    uci_free_context(ctx);
    free(param);
}

bool uci_get_bool_option(char* str) {
    char value[256];
    uci_get_option(str, value);
    bool result = (value != NULL && ((strcmp(value, "1") == 0) || (strcmp(value, "on") == 0)));
    return result;
}

//Function equivalent to the uci set command.
bool uci_set_option(char* str) {
    struct uci_context *ctx;
    struct uci_ptr ptr;
    int ret = UCI_OK;

    ctx = uci_alloc_context();

    char* param = strdup(str);

    if (uci_lookup_ptr(ctx, &ptr, param, true) != UCI_OK) {
        uci_perror(ctx, "uci set error");
        uci_free_context(ctx);
        return false;
    }

    if (ptr.value)
        ret = uci_set(ctx, &ptr);
    else {
        ret = UCI_ERR_PARSE;
        uci_free_context(ctx);
        return false;
    }

    if (ret == UCI_OK) {
        uci_save(ctx, ptr.p);
        uci_commit(ctx, &ptr.p, true);
    }

    uci_free_context(ctx);
    return true;
}