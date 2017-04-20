/*
 * Copyright (c) 2016 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#include "bignum.hpp"
#include "buffer.hpp"

#include <assert.h>
#include <math.h>
#include <inttypes.h>

static void bignum_normalize(BigNum *bn) {
    assert(bn->kind == BigNumKindInt);
    if (bn->data.x_uint == 0) {
        bn->is_negative = false;
    }
}

void bignum_init_float(BigNum *dest, double x) {
    dest->kind = BigNumKindFloat;
    dest->is_negative = false;
    dest->data.x_float = x;
}

void bignum_init_unsigned(BigNum *dest, uint64_t x) {
    dest->kind = BigNumKindInt;
    dest->is_negative = false;
    dest->data.x_uint = x;
}

void bignum_init_signed(BigNum *dest, int64_t x) {
    dest->kind = BigNumKindInt;
    if (x < 0) {
        dest->is_negative = true;
        dest->data.x_uint = ((uint64_t)(-(x + 1))) + 1;
    } else {
        dest->is_negative = false;
        dest->data.x_uint = x;
    }
}

void bignum_init_bignum(BigNum *dest, BigNum *src) {
    safe_memcpy(dest, src, 1);
}

static int u64_log2(uint64_t x) {
    int result = 0;
    for (; x != 0; x >>= 1) {
        result += 1;
    }
    return result;
}

bool bignum_fits_in_bits(BigNum *bn, int bit_count, bool is_signed) {
    assert(bn->kind == BigNumKindInt);

    if (is_signed) {
        uint64_t max_neg;
        uint64_t max_pos;
        if (bit_count < 64) {
            max_neg = (1ULL << (bit_count - 1));
            max_pos = max_neg - 1;
        } else {
            max_pos = ((uint64_t)INT64_MAX);
            max_neg = max_pos + 1;
        }
        uint64_t max_val = bn->is_negative ? max_neg : max_pos;
        return bn->data.x_uint <= max_val;
    } else {
        if (bn->is_negative) {
            return bn->data.x_uint == 0;
        } else {
            int required_bit_count = u64_log2(bn->data.x_uint);
            return bit_count >= required_bit_count;
        }
    }
}

void bignum_truncate(BigNum *bn, int bit_count) {
    assert(bn->kind == BigNumKindInt);
    // TODO handle case when negative = true
    if (bit_count < 64) {
        bn->data.x_uint &= (1LL << bit_count) - 1;
    }
}

uint64_t bignum_to_twos_complement(BigNum *bn) {
    assert(bn->kind == BigNumKindInt);

    if (bn->is_negative) {
        int64_t x = bn->data.x_uint;
        return -x;
    } else {
        return bn->data.x_uint;
    }
}

// returns true if overflow happened
bool bignum_add(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    dest->kind = op1->kind;

    if (dest->kind == BigNumKindFloat) {
        dest->data.x_float = op1->data.x_float + op2->data.x_float;
        return false;
    }

    if (op1->is_negative == op2->is_negative) {
        dest->is_negative = op1->is_negative;
        return __builtin_uaddll_overflow(op1->data.x_uint, op2->data.x_uint, &dest->data.x_uint);
    } else if (!op1->is_negative && op2->is_negative) {
        if (__builtin_usubll_overflow(op1->data.x_uint, op2->data.x_uint, &dest->data.x_uint)) {
            dest->data.x_uint = (UINT64_MAX - dest->data.x_uint) + 1;
            dest->is_negative = true;
            bignum_normalize(dest);
            return false;
        } else {
            bignum_normalize(dest);
            return false;
        }
    } else {
        return bignum_add(dest, op2, op1);
    }
}

void bignum_negate(BigNum *dest, BigNum *op) {
    dest->kind = op->kind;

    if (dest->kind == BigNumKindFloat) {
        dest->data.x_float = -op->data.x_float;
    } else {
        dest->data.x_uint = op->data.x_uint;
        dest->is_negative = !op->is_negative;
        bignum_normalize(dest);
    }
}

void bignum_not(BigNum *dest, BigNum *op, int bit_count, bool is_signed) {
    assert(op->kind == BigNumKindInt);
    uint64_t bits = ~bignum_to_twos_complement(op);
    if (bit_count < 64) {
        bits &= (1LL << bit_count) - 1;
    }
    if (is_signed)
        bignum_init_signed(dest, bits);
    else
        bignum_init_unsigned(dest, bits);
}

void bignum_cast_to_float(BigNum *dest, BigNum *op) {
    assert(op->kind == BigNumKindInt);
    dest->kind = BigNumKindFloat;

    dest->data.x_float = (double)op->data.x_uint;

    if (op->is_negative) {
        dest->data.x_float = -dest->data.x_float;
    }
}

void bignum_cast_to_int(BigNum *dest, BigNum *op) {
    assert(op->kind == BigNumKindFloat);
    dest->kind = BigNumKindInt;

    if (op->data.x_float >= 0) {
        dest->data.x_uint = (unsigned long long)op->data.x_float;
        dest->is_negative = false;
    } else {
        dest->data.x_uint = (unsigned long long)-op->data.x_float;
        dest->is_negative = true;
    }
}

bool bignum_sub(BigNum *dest, BigNum *op1, BigNum *op2) {
    BigNum op2_negated;
    bignum_negate(&op2_negated, op2);
    return bignum_add(dest, op1, &op2_negated);
}

bool bignum_mul(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    dest->kind = op1->kind;

    if (dest->kind == BigNumKindFloat) {
        dest->data.x_float = op1->data.x_float * op2->data.x_float;
        return false;
    }

    if (__builtin_umulll_overflow(op1->data.x_uint, op2->data.x_uint, &dest->data.x_uint)) {
        return true;
    }

    dest->is_negative = op1->is_negative != op2->is_negative;
    bignum_normalize(dest);
    return false;
}

bool bignum_div(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    dest->kind = op1->kind;

    if (dest->kind == BigNumKindFloat) {
        dest->data.x_float = op1->data.x_float / op2->data.x_float;
    } else {
        dest->data.x_uint = op1->data.x_uint / op2->data.x_uint;
        dest->is_negative = op1->is_negative != op2->is_negative;
        bignum_normalize(dest);
    }
    return false;
}

bool bignum_rem(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    dest->kind = op1->kind;

    if (dest->kind == BigNumKindFloat) {
        dest->data.x_float = fmod(op1->data.x_float, op2->data.x_float);
    } else {
        if (op1->is_negative || op2->is_negative) {
            zig_panic("TODO handle remainder division with negative numbers");
        }
        dest->data.x_uint = op1->data.x_uint % op2->data.x_uint;
        bignum_normalize(dest);
    }
    return false;
}

bool bignum_or(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == BigNumKindInt);
    assert(op2->kind == BigNumKindInt);

    assert(!op1->is_negative);
    assert(!op2->is_negative);

    dest->kind = BigNumKindInt;
    dest->data.x_uint = op1->data.x_uint | op2->data.x_uint;
    return false;
}

bool bignum_and(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == BigNumKindInt);
    assert(op2->kind == BigNumKindInt);

    assert(!op1->is_negative);
    assert(!op2->is_negative);

    dest->kind = BigNumKindInt;
    dest->data.x_uint = op1->data.x_uint & op2->data.x_uint;
    return false;
}

bool bignum_xor(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == BigNumKindInt);
    assert(op2->kind == BigNumKindInt);

    assert(!op1->is_negative);
    assert(!op2->is_negative);

    dest->kind = BigNumKindInt;
    dest->data.x_uint = op1->data.x_uint ^ op2->data.x_uint;
    return false;
}

bool bignum_shl(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == BigNumKindInt);
    assert(op2->kind == BigNumKindInt);

    assert(!op1->is_negative);
    assert(!op2->is_negative);

    dest->kind = BigNumKindInt;
    dest->data.x_uint = op1->data.x_uint << op2->data.x_uint;
    return false;
}

bool bignum_shr(BigNum *dest, BigNum *op1, BigNum *op2) {
    assert(op1->kind == BigNumKindInt);
    assert(op2->kind == BigNumKindInt);

    assert(!op1->is_negative);
    assert(!op2->is_negative);

    dest->kind = BigNumKindInt;
    dest->data.x_uint = op1->data.x_uint >> op2->data.x_uint;
    return false;
}


Buf *bignum_to_buf(BigNum *bn) {
    if (bn->kind == BigNumKindFloat) {
        return buf_sprintf("%f", bn->data.x_float);
    } else {
        const char *neg = bn->is_negative ? "-" : "";
        return buf_sprintf("%s%llu", neg, bn->data.x_uint);
    }
}

bool bignum_cmp_eq(BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    if (op1->kind == BigNumKindFloat) {
        return op1->data.x_float == op2->data.x_float;
    } else {
        return op1->data.x_uint == op2->data.x_uint &&
            (op1->is_negative == op2->is_negative || op1->data.x_uint == 0);
    }
}

bool bignum_cmp_neq(BigNum *op1, BigNum *op2) {
    return !bignum_cmp_eq(op1, op2);
}

bool bignum_cmp_lt(BigNum *op1, BigNum *op2) {
    return !bignum_cmp_gte(op1, op2);
}

bool bignum_cmp_gt(BigNum *op1, BigNum *op2) {
    return !bignum_cmp_lte(op1, op2);
}

bool bignum_cmp_lte(BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);
    if (op1->kind == BigNumKindFloat) {
        return (op1->data.x_float <= op2->data.x_float);
    }

    // assume normalized is_negative
    if (!op1->is_negative && !op2->is_negative) {
        return op1->data.x_uint <= op2->data.x_uint;
    } else if (op1->is_negative && op2->is_negative) {
        return op1->data.x_uint >= op2->data.x_uint;
    } else if (op1->is_negative && !op2->is_negative) {
        return true;
    } else {
        return false;
    }
}

bool bignum_cmp_gte(BigNum *op1, BigNum *op2) {
    assert(op1->kind == op2->kind);

    if (op1->kind == BigNumKindFloat) {
        return (op1->data.x_float >= op2->data.x_float);
    }

    // assume normalized is_negative
    if (!op1->is_negative && !op2->is_negative) {
        return op1->data.x_uint >= op2->data.x_uint;
    } else if (op1->is_negative && op2->is_negative) {
        return op1->data.x_uint <= op2->data.x_uint;
    } else if (op1->is_negative && !op2->is_negative) {
        return false;
    } else {
        return true;
    }
}

bool bignum_increment_by_scalar(BigNum *bignum, uint64_t scalar) {
    assert(bignum->kind == BigNumKindInt);
    assert(!bignum->is_negative);
    return __builtin_uaddll_overflow(bignum->data.x_uint, scalar, &bignum->data.x_uint);
}

bool bignum_multiply_by_scalar(BigNum *bignum, uint64_t scalar) {
    assert(bignum->kind == BigNumKindInt);
    assert(!bignum->is_negative);
    return __builtin_umulll_overflow(bignum->data.x_uint, scalar, &bignum->data.x_uint);
}

uint32_t bignum_ctz(BigNum *bignum, uint32_t bit_count) {
    assert(bignum->kind == BigNumKindInt);

    uint64_t x = bignum_to_twos_complement(bignum);
    uint32_t result = 0;
    for (uint32_t i = 0; i < bit_count; i += 1) {
        if ((x & 0x1) != 0)
            break;

        result += 1;
        x = x >> 1;
    }
    return result;
}

uint32_t bignum_clz(BigNum *bignum, uint32_t bit_count) {
    assert(bignum->kind == BigNumKindInt);

    if (bit_count == 0)
        return 0;

    uint64_t x = bignum_to_twos_complement(bignum);
    uint64_t mask = ((uint64_t)1) << ((uint64_t)bit_count - 1);
    uint32_t result = 0;
    for (uint32_t i = 0; i < bit_count; i += 1) {
        if ((x & mask) != 0)
            break;

        result += 1;
        x = x << 1;
    }
    return result;
}
