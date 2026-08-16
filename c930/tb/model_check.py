#!/usr/bin/env python3
"""
Cycle-accurate model of the c930 systolic GEMM dataflow.

Mirrors c930_npu_core / c930_systolic_array timing exactly:
  * PE(r,c): o_a_out <= i_a_in ; o_ps_out <= i_ps_in + i_a_in * w(r,c)
  * activation skew : row r pulses A[m][k_base+r] at cycle t == r
  * accumulator skew: column n pulses acc[n]         at cycle t == n
  * capture         : at cycle t >= kr, acc[t-kr] = bottom output of col t-kr
  * K-tiling        : tiles of NUM_ROWS, accumulator fed back between tiles

Run: python3 c930/tb/model_check.py
"""
import random


def systolic_gemm(A, B, R, N):
    """C = A @ B with the systolic dataflow described above.

    A: list of rows (M x K), B: list of rows (K x N).
    R: systolic rows (reduction per pass), N: systolic cols (output width).
    """
    M = len(A)
    K = len(A[0])
    assert all(len(r) == N for r in B) and len(B) == K
    C = []
    for m in range(M):
        acc = [0] * N
        kt = 0
        while kt < K:
            kr = min(R, K - kt)

            # weight register of PE(r, c) for this tile
            w = [[0] * N for _ in range(R)]
            for r in range(kr):
                for c in range(N):
                    w[r][c] = B[kt + r][c]

            # registered PE outputs (o_a_out, o_ps_out)
            a_reg = [[0] * N for _ in range(R)]
            ps_reg = [[0] * N for _ in range(R)]

            for t in range(R + N):
                # --- capture (reads OLD ps_reg, result of cycle t-1) ---
                # The result for column c drains through the whole column and
                # reaches the bottom edge at cycle R + c (partial tiles drain
                # through the unused zero rows too).
                if t >= R:
                    acc[t - R] = ps_reg[R - 1][t - R]

                # --- edge feeds (skew) ---
                act = [0] * R
                ps_edge = [0] * N
                for r in range(R):
                    if t == r and r < kr:
                        act[r] = A[m][kt + r]
                for n in range(N):
                    if t == n:
                        ps_edge[n] = acc[n]

                # --- registered update ---
                new_a = [[0] * N for _ in range(R)]
                new_ps = [[0] * N for _ in range(R)]
                for r in range(R):
                    for c in range(N):
                        a_in = act[r] if c == 0 else a_reg[r][c - 1]
                        ps_in = ps_edge[c] if r == 0 else ps_reg[r - 1][c]
                        new_a[r][c] = a_in
                        new_ps[r][c] = ps_in + a_in * w[r][c]
                a_reg, ps_reg = new_a, new_ps

            kt += R
        C.append(acc)
    return C


def reference(A, B):
    M, K = len(A), len(A[0])
    N = len(B[0])
    return [
        [sum(A[m][k] * B[k][n] for k in range(K)) for n in range(N)]
        for m in range(M)
    ]


def check(name, A, B, R, N):
    got = systolic_gemm(A, B, R, N)
    exp = reference(A, B)
    assert got == exp, f"{name} mismatch:\n got={got}\n exp={exp}"
    print(f"[PASS] {name}  (M={len(A)} K={len(A[0])} N={N} R={R})")


def main():
    random.seed(12345)

    # deterministic 1x2x2 (hand-computed: C = [[-7, 14]])
    check("deterministic 1x2x2", [[3, -2]], [[1, 4], [5, -1]], R=4, N=2)

    # random tiling: K=6 with R=4 -> tiles kr=4, kr=2
    A = [[random.randint(-8, 8) for _ in range(6)] for _ in range(2)]
    B = [[random.randint(-8, 8) for _ in range(3)] for _ in range(6)]
    check("random 2x6x3 tiling", A, B, R=4, N=3)

    # bigger: K=10 with R=4 -> tiles kr=4,4,2 ; N=4
    A = [[random.randint(-8, 8) for _ in range(10)] for _ in range(5)]
    B = [[random.randint(-8, 8) for _ in range(4)] for _ in range(10)]
    check("random 5x10x4 tiling", A, B, R=4, N=4)

    # exact single tile: K=4 == R
    A = [[random.randint(-8, 8) for _ in range(4)] for _ in range(3)]
    B = [[random.randint(-8, 8) for _ in range(2)] for _ in range(4)]
    check("random 3x4x2 single tile", A, B, R=4, N=2)

    print("[PASS] all model checks passed")


if __name__ == "__main__":
    main()
