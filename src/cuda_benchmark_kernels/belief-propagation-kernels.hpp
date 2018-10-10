#ifndef BELIEF_PROPAGATION_KERNELS_HPP
#define BELIEF_PROPAGATION_KERNELS_HPP

#include <stdio.h>
#include <assert.h>
#include <time.h>
#include <math.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

extern "C" {
#include "../bnf-parser/expression.h"
#include "../bnf-parser/Parser.h"
#include "../bnf-parser/Lexer.h"
#include "../bnf-xml-parser/xml-expression.h"
#include "../snap-parser/snap-parser.h"
#include "../csr-parser/csr-parser.h"
}

void CheckCudaErrorAux (const char *, unsigned, const char *, cudaError_t);
#define CUDA_CHECK_RETURN(value) CheckCudaErrorAux(__FILE__,__LINE__, #value, value)

__global__
void init_message_buffer_kernel(struct belief *, struct belief *, int);

__device__
void combine_message_cuda(struct belief *, struct belief *, int, int,
                          int, int, char, int);

__device__
void combine_page_rank_message_cuda(struct belief *, struct belief *, int, int,
                          int, int, char, int);

__device__
void combine_viterbi_message_cuda(struct belief *, struct belief *, int, int,
                                  int, int, char, int);

__global__
void read_incoming_messages_kernel(struct belief *, struct belief *, int *,
                                   int *, int,
                                   int,
                                   char, int);

__device__
void send_message_for_edge_cuda(struct belief * message_buffer, int edge_index, int node_index,
                                struct joint_probability * joint_probabilities,
                                struct belief * edge_messages);

__global__
void send_message_for_node_kernel(struct belief *, int,
                                  struct joint_probability *, struct belief *,
                                  int *, int *, int);

__global__
void marginalize_node_combine_kernel(struct belief *, struct belief *,
                                     struct belief *, int *, int *, int,
                                     int, char, int);

__global__
void marginalize_page_rank_node_combine_kernel(struct belief *, struct belief *,
                                     struct belief *, int *, int *, int,
                                     int, char, int);

__global__
void argmax_node_combine_kernel(struct belief *, struct belief *,
                           struct belief *, int *, int *, int,
                           int, char, int);

__global__
void marginalize_sum_node_kernel(struct belief *, struct belief *,
                                 struct belief *, int *,
                                 int *, int,
                                 int, char, int);

__global__
void marginalize_dampening_factor_kernel(struct belief *, struct belief *,
                                         struct belief *, int *,
                                         int *, int,
                                         int, char, int);

__global__
void marginalize_viterbi_beliefs(struct belief *, int);

__global__
void argmax_kernel(struct belief *, struct belief *,
                   struct belief *, int *,
                   int *, int,
                   int, char, int);

__device__
float calculate_local_delta(int, struct belief *);

__global__
void calculate_delta_6(struct belief *, float *, float *,
                       int, char, int);

__global__
void calculate_delta_simple(struct belief *, float *, float *,
                            int);

void check_cuda_kernel_return_code();

int loopy_propagate_until_cuda_kernels(Graph_t, float, int);
int page_rank_until_cuda_kernels(Graph_t, float, int);
int viterbi_until_cuda_kernels(Graph_t, float, int);


void test_loopy_belief_propagation_kernels(char *);

void run_test_loopy_belief_propagation_kernels(struct expression *, const char *, FILE *);
void run_test_loopy_belief_propagation_xml_file_kernels(const char *, FILE *);
void run_test_loopy_belief_propagation_snap_file_kernels(const char *, const char *, FILE *);
void run_test_loopy_belief_propagation_mtx_files_kernels(const char *, const char *, FILE *);


__global__
void calculate_delta(struct belief * previous_messages, struct belief * current_messages, float * delta, float * delta_array, int * edges_x_dim, int num_edges);

#endif