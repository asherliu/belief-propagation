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
}

int yyparse(struct expression ** expr, yyscan_t scanner);

static void CheckCudaErrorAux (const char *, unsigned, const char *, cudaError_t);
#define CUDA_CHECK_RETURN(value) CheckCudaErrorAux(__FILE__,__LINE__, #value, value)

__global__
void init_message_buffer_kernel(float *message_buffer, float *node_states, unsigned int *node_num_vars,
                                unsigned int num_nodes){
    unsigned int node_index, state_index, num_variables;

    node_index = blockIdx.x*blockDim.x + threadIdx.x;
    state_index = blockIdx.y*blockDim.y + threadIdx.y;

    if(node_index < num_nodes){
        num_variables = node_num_vars[node_index];

        if(state_index < num_variables){
            message_buffer[node_index * MAX_STATES + state_index] = node_states[node_index * MAX_STATES + state_index];
        }
    }
}

__device__
void combine_message_cuda(float * dest, float * edge_messages, unsigned int length, unsigned int node_index,
                          unsigned int edge_offset, unsigned int num_edges, char n_is_pow_2, unsigned int warp_size){
    extern __shared__ float shared_message[];

    unsigned int offset;

    unsigned int tid = threadIdx.y;
    unsigned int i = blockIdx.y * blockDim.y * 2 + threadIdx.y;
    unsigned int grid_size = blockDim.y * 2 * gridDim.y;

    float my_value = 1.0;

    while ( i < length && (edge_offset + i) < num_edges ) {
        my_value = edge_messages[edge_offset + i];

        //ensure we don't read out of bounds
        if (n_is_pow_2 || i + blockDim.y < length) {
            my_value *= edge_messages[edge_offset + i];
        }

        i += grid_size;
    }

    shared_message[tid] = my_value;
    __syncthreads();

    // do reduction in shared mem
    if((blockDim.y >= 512 && (tid < 256))){
        shared_message[tid] = my_value = my_value * shared_message[tid + 256];
    }
    __syncthreads();
    if((blockDim.y >= 256) && (tid < 128)){
        shared_message[tid] = my_value = my_value * shared_message[tid + 128];
    }
    __syncthreads();
    if((blockDim.y >= 128) && (tid < 64)){
        shared_message[tid] = my_value = my_value * shared_message[tid + 64];
    }
    __syncthreads();
#if (__CUDA_ARCH__ >= 300)
    if( tid < 32){
        // fetch final intermediate sum from 2nd warp
        if(blockDim.x >= 64){
            my_value *= shared_message[tid + 32];
        }
        for(offset = warp_size/2; offset > 0; offset /= 2 ){
            my_value *= __shfl_down(my_value, offset);
        }
    }
#else
    // fully unroll reduction within a single warp
    if((blockDim.y >= 64) && (tid < 32)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 32];
    }
    __syncthreads();

    if((blockDim.y >= 32) && (tid < 16)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 16];
    }
    __syncthreads();
    if((blockDim.y >= 16) && (tid < 8)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 8];
    }
    __syncthreads();
    if((blockDim.y >= 8) && (tid < 4)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 4];
    }
    __syncthreads();
    if((blockDim.y >= 4) && (tid < 2)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 2];
    }
    __syncthreads();
    if((blockDim.y >= 2) && (tid < 1)) {
        shared_message[tid] = my_value = my_value * shared_message[tid + 1];
    }
    __syncthreads();
#endif
    // write result for this block back to global mem
    if(tid == 0){
        dest[node_index] = my_value;
    }
}
__global__
void read_incoming_messages_kernel(float *message_buffer, float *previous_messages,
                                   unsigned int * dest_node_to_edges,
                                   unsigned int current_num_edges,
                                   unsigned int *node_num_vars, unsigned int num_vertices,
                                   char n_is_pow_2, unsigned int warp_size){
    unsigned int node_index, edge_index, start_index, end_index, diff_index, tmp_index, num_variables;

    node_index = blockIdx.x*blockDim.x + threadIdx.x;
    edge_index = blockIdx.y*blockDim.y + threadIdx.y;

    if(node_index < num_vertices) {
        num_variables = node_num_vars[node_index];

        start_index = dest_node_to_edges[node_index];
        if (node_index + 1 >= num_vertices) {
            end_index = num_vertices + current_num_edges;
        } else {
            end_index = dest_node_to_edges[node_index + 1];
        }
        diff_index = end_index - start_index;
        if (edge_index < diff_index) {
            tmp_index = dest_node_to_edges[edge_index + start_index];
            combine_message_cuda(message_buffer, previous_messages, num_variables, MAX_STATES * node_index,
                                 MAX_STATES * tmp_index, current_num_edges, n_is_pow_2, warp_size);
        }
    }
}

__device__
void send_message_for_edge_cuda(float * message_buffer, unsigned int edge_index, unsigned int node_index,
                                float * joint_probabilities, float * edge_messages,
                                unsigned int * x_dim, unsigned int * y_dim){
    unsigned int i, j, num_src, num_dest;
    float sum;

    num_src = x_dim[edge_index];
    num_dest = y_dim[edge_index];

    sum = 0.0f;
    sum = 0.0;
    for(i = 0; i < num_src; ++i){
        edge_messages[edge_index * MAX_STATES + i] = 0.0;
        for(j = 0; j < num_dest; ++j){
            edge_messages[edge_index * MAX_STATES + i] += joint_probabilities[MAX_STATES * MAX_STATES * edge_index + MAX_STATES * i + j] * message_buffer[MAX_STATES * node_index + j];
        }
        sum += edge_messages[edge_index * MAX_STATES + i];
    }
    if(sum <= 0.0){
        sum = 1.0;
    }
    for(i = 0; i < num_src; ++i){
        edge_messages[edge_index * MAX_STATES + i] = edge_messages[edge_index * MAX_STATES + i] / sum;
    }
}

__global__
void send_message_for_node_kernel(float * message_buffer, unsigned int current_num_edges,
                                  float * joint_probabilities, float * current_edge_messages,
                                  unsigned int * src_node_to_edges, unsigned int * edges_x_dim, unsigned int * edges_y_dim,
                                  unsigned int num_vertices){
    unsigned int node_index, edge_index, start_index, end_index, diff_index;

    node_index = blockIdx.x*blockDim.x + threadIdx.x;
    edge_index = blockIdx.y*blockDim.y + threadIdx.y;

    if(node_index < num_vertices){
        start_index = src_node_to_edges[node_index];
        if(node_index + 1 >= num_vertices){
            end_index = num_vertices + current_num_edges;
        }
        else{
            end_index = src_node_to_edges[node_index + 1];
        }

        diff_index = end_index - start_index;
        if(edge_index < diff_index){
            edge_index = src_node_to_edges[edge_index + start_index];
            send_message_for_edge_cuda(message_buffer, edge_index, node_index, joint_probabilities, current_edge_messages, edges_x_dim, edges_y_dim);
        }
    }
}

__global__
void marginalize_node_kernel(unsigned int * node_num_vars, float * message_buffer, float * node_states,
                             float * current_edges_messages, unsigned int * dest_node_to_edges,
                             unsigned int num_vertices,
                             unsigned int num_edges, char n_is_pow_2, unsigned int warp_size){
    unsigned int node_index, edge_index, temp_edge_index, i, num_variables, start_index, end_index, diff_index;
    char has_incoming;
    float sum;

    node_index = blockIdx.x*blockDim.x + threadIdx.x;
    edge_index = blockIdx.y*blockDim.y + threadIdx.y;

    if(node_index < num_vertices) {
        has_incoming = 0;
        num_variables = node_num_vars[node_index];

        if(edge_index == 0){
            for(i = 0; i < num_variables; ++i){
                message_buffer[MAX_STATES * node_index + i] = 1.0;
            }
        }

        start_index = dest_node_to_edges[node_index];
        if(node_index + 1 >= num_vertices){
            end_index = num_vertices + num_edges;
        }
        else{
            end_index = dest_node_to_edges[node_index + 1];
        }

        diff_index = end_index - start_index;
        if(edge_index < diff_index){
            temp_edge_index = dest_node_to_edges[edge_index + start_index];

            __syncthreads();

            combine_message_cuda(message_buffer, current_edges_messages, num_variables, node_index * MAX_STATES, temp_edge_index * MAX_STATES, num_edges, n_is_pow_2, warp_size);
            if(edge_index == 0){
                has_incoming = 1;
            }
            __syncthreads();
        }
        if(edge_index == 0){
            if(has_incoming > 0) {
                for (i = 0; i < num_variables; ++i) {
                    node_states[MAX_STATES * node_index + i] = message_buffer[MAX_STATES * node_index + i];
                }
            }
            sum = 0.0;
            for(i = 0; i < num_variables; ++i){
                sum += node_states[MAX_STATES * node_index + i];
            }
            if(sum <= 0.0){
                sum = 1.0;
            }
            for(i = 0; i < num_variables; ++i){
                node_states[MAX_STATES * node_index + i] = node_states[MAX_STATES * node_index + i] / sum;
            }
        }
    }
}

__device__
float calculate_local_delta(unsigned int i, float * previous_messages, float * current_messages, unsigned int * edges_x_dim){
    float delta, diff;
    unsigned int k;

    delta = 0.0;

    for(k = 0; k < edges_x_dim[i]; ++k){
        diff = previous_messages[MAX_STATES * i + k] - current_messages[MAX_STATES * i + k];
        if(diff != diff){
            diff = 0.0;
        }
        delta += fabs(diff);
    }

    return delta;
}

__global__
void calculate_delta(float * previous_messages, float * current_messages, float * delta, float * delta_array, unsigned int * edges_x_dim, unsigned int num_edges){
    extern __shared__ float shared_delta[];
    unsigned int tid, idx, i, s;

    tid = threadIdx.x;
    idx = blockIdx.x*blockDim.x + threadIdx.x;
    i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;

    if(idx < num_edges){
        delta_array[idx] = calculate_local_delta(idx, previous_messages, current_messages, edges_x_dim);
    }
    __syncthreads();

    float my_delta = (i < num_edges) ? delta_array[i] : 0;

    if(i + BLOCK_SIZE < num_edges){
        my_delta += delta_array[i + BLOCK_SIZE];
    }

    shared_delta[tid] = my_delta;
    __syncthreads();

    // do reduction in shared mememory
    for(s= blockDim.x / 2; s > 32; s>>=1){
        if(tid < s){
            shared_delta[tid] = my_delta = my_delta + shared_delta[tid + s];
        }

        __syncthreads();
    }

#if (__CUDA_ARCH__ >= 300)
    if(tid < 32){
        //fetch final intermediate sum from second warp
        if(BLOCK_SIZE >= 64){
            my_delta += shared_delta[tid + 32];
        }
        for(s = WARP_SIZE/2; s > 0; s /= 2){
            my_delta += __shfl_down(my_delta, s);
        }
    }
#else
    if((BLOCK_SIZE >= 64) && (tid < 32)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 32];
    }
    __syncthreads();
    if((BLOCK_SIZE >= 32) && (tid < 16)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 16];
    }
    __syncthreads();
    if((BLOCK_SIZE >= 16) && (tid < 8)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 8];
    }
    __syncthreads();
    if((BLOCK_SIZE >= 8) && (tid < 4)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 4];
    }
    __syncthreads();
    if((BLOCK_SIZE >= 4) && (tid < 2)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 2];
    }
    __syncthreads();
    if((BLOCK_SIZE >= 2) && (tid < 1)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 1];
    }
    __syncthreads();
#endif
    if(tid == 0) {
        *delta = my_delta;
    }
}

__global__
void calculate_delta_6(float * previous_messages, float * current_messages, float * delta, float * delta_array,
                       unsigned int * edges_x_dim,
                       unsigned int num_edges, char n_is_pow_2, unsigned int warp_size) {
    extern __shared__ float shared_delta[];

    unsigned int offset;
    // perform first level of reduce
    // reading from global memory, writing to shared memory
    unsigned int idx =  blockIdx.x*blockDim.x + threadIdx.x;
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x * 2 + threadIdx.x;
    unsigned int grid_size = blockDim.x * 2 * gridDim.x;

    if(idx < num_edges){
        delta_array[i] = calculate_local_delta(idx, previous_messages, current_messages, edges_x_dim);
    }
    __syncthreads();

    float my_delta = 0.0;

    while (i < num_edges) {
        my_delta = delta_array[i];

        // ensure we don't read out of bounds
        if (n_is_pow_2 || i + blockDim.x < num_edges) {
            my_delta += delta_array[i];
        }

        i += grid_size;
    }

    //each thread puts its local sum into shared memory
    shared_delta[tid] = my_delta;
    __syncthreads();

    // do reduction in shared mem
    if ((blockDim.x >= 512) && (tid < 256)) {
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 256];
    }
    __syncthreads();
    if ((blockDim.x >= 256) && (tid < 128)) {
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 128];
    }
    __syncthreads();
    if ((blockDim.x >= 128) && (tid < 64)) {
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 64];
    }
    __syncthreads();

#if (__CUDA_ARCH__ >= 300)
    if( tid < 32){
        // fetch final intermediate sum from 2nd warp
        if(blockDim.x >= 64){
            my_delta += shared_delta[tid + 32];
        }
        for(offset = warp_size/2; offset > 0; offset /= 2 ){
            my_delta += __shfl_down(my_delta, offset);
        }
    }
#else
    // fully unroll reduction within a single warp
    if ((blockDim.x >= 64) && (tid < 32)) {
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 32];
    }
    __syncthreads();

    if ((blockDim.x >= 32) && (tid < 16)) {
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 16];
    }
    __syncthreads();

    if((blockDim.x >= 16) && (tid < 8)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 8];
    }
    __syncthreads();

    if((blockDim.x >= 8) && (tid < 4)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 4];
    }
    __syncthreads();

    if((blockDim.x >= 4) && (tid < 2)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 2];
    }
    __syncthreads();

    if((blockDim.x >= 2) && (tid < 1)){
        shared_delta[tid] = my_delta = my_delta + shared_delta[tid + 1];
    }
    __syncthreads();

#endif
    //write result for this block to global mem
    if(tid == 0){
        *delta = my_delta;
    }
}

__global__
void calculate_delta_simple(float * previous_messages, float * current_messages,
                            float * delta, float * delta_array, unsigned int * edges_x_dim,
                            unsigned int num_edges) {
    extern __shared__ float shared_delta[];
    unsigned int tid, idx, i, s;

    tid = threadIdx.x;
    idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < num_edges) {
        delta_array[idx] = calculate_local_delta(idx, previous_messages, current_messages, edges_x_dim);
    }
    __syncthreads();

    shared_delta[tid] = (idx < num_edges) ? delta_array[idx] : 0;

    __syncthreads();

    // do reduction in shared mem
    for(s = 1; s < blockDim.x; s *= 2){
        i = 2 * s * tid;
        if( i < blockDim.x ) {
            shared_delta[i] += shared_delta[i + s];
        }

        __syncthreads();
    }

    //write result for this block to global mem
    if(tid == 0){
        *delta = shared_delta[0];
    }
}

static void prepare_unsigned_int_text(texture<unsigned int, cudaTextureType1D, cudaReadModeElementType> * tex){
    tex->addressMode[0] = cudaAddressModeWrap;
    tex->addressMode[1] = cudaAddressModeWrap;
    tex->filterMode = cudaFilterModePoint;
    tex->normalized = 1;
}

static void check_cuda_kernel_return_code(){
    cudaError_t err;

    err = cudaGetLastError();
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: %s\n", cudaGetErrorString(err));
        exit(-1);
    }
}

unsigned int loopy_propagate_until_cuda(Graph_t graph, float convergence, unsigned int max_iterations){
    unsigned int i, j, num_iter, num_vertices, num_edges;
    float * delta;
    float * delta_array;
    float previous_delta, host_delta;
    char is_pow_2;

    float * edges_joint_probabilities;

    float * message_buffer;

    float * current_messages;
    float * previous_messages;
    float * temp;

    unsigned int * edges_x_dim;
    unsigned int * edges_y_dim;

    unsigned int * src_nodes_to_edges;
    unsigned int * dest_nodes_to_edges;

    float * node_states;
    unsigned int * node_num_vars;

    host_delta = 0.0;

    num_vertices = graph->current_num_vertices;
    num_edges = graph->current_num_edges;

    /*printf("Before=====");
    print_edges(graph);
    print_nodes(graph);*/


    is_pow_2 = num_vertices % 2 == 0;

    // allocate data
    CUDA_CHECK_RETURN(cudaMalloc((void**)&edges_x_dim, sizeof(unsigned int) * graph->current_num_edges));
    CUDA_CHECK_RETURN(cudaMalloc((void**)&edges_y_dim, sizeof(unsigned int) * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&edges_joint_probabilities, sizeof(float) * MAX_STATES * MAX_STATES * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&dest_nodes_to_edges, sizeof(unsigned int) * (graph->current_num_edges + graph->current_num_vertices)));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&src_nodes_to_edges, sizeof(unsigned int) * (graph->current_num_edges + graph->current_num_vertices)));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&current_messages, sizeof(float) * MAX_STATES * graph->current_num_edges));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&previous_messages, sizeof(float) * MAX_STATES * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&node_states, sizeof(float) * MAX_STATES * graph->current_num_vertices));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&node_num_vars, sizeof(unsigned int) * graph->current_num_vertices));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&delta, sizeof(float)));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&delta_array, sizeof(float) * num_vertices));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&message_buffer, sizeof(float) * num_vertices * MAX_STATES));

    // copy data
    CUDA_CHECK_RETURN(cudaMemcpy(edges_joint_probabilities, graph->edges_joint_probabilities, sizeof(float) * MAX_STATES * MAX_STATES * graph->current_num_edges, cudaMemcpyHostToDevice ));

    CUDA_CHECK_RETURN(cudaMemcpy(current_messages, graph->edges_messages, sizeof(float) * MAX_STATES * graph->current_num_edges, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(current_messages, graph->last_edges_messages, sizeof(float) * MAX_STATES * graph->current_num_edges, cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(node_num_vars, graph->node_num_vars, sizeof(unsigned int) * graph->current_num_vertices, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(node_states, graph->node_states, sizeof(float) * MAX_STATES * graph->current_num_vertices, cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(dest_nodes_to_edges, graph->dest_nodes_to_edges, sizeof(unsigned int) * (graph->current_num_vertices + graph->current_num_edges), cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(src_nodes_to_edges, graph->src_nodes_to_edges, sizeof(unsigned int) * (graph->current_num_vertices + graph->current_num_edges), cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(edges_x_dim, graph->edges_x_dim, sizeof(unsigned int) * num_edges, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(edges_y_dim, graph->edges_y_dim, sizeof(unsigned int) * num_edges, cudaMemcpyHostToDevice));


    const int blockEdge1dCount = (num_edges + BLOCK_SIZE - 1)/ BLOCK_SIZE;
    const int blockEdge2dCount = (num_edges + BLOCK_SIZE_2_D - 1)/ BLOCK_SIZE_2_D;
    const int blockNodeCount = (num_vertices + BLOCK_SIZE_2_D - 1)/BLOCK_SIZE_2_D;
    const int blockStateCount = (MAX_STATES + BLOCK_SIZE_2_D - 1)/BLOCK_SIZE_2_D;
    const int blockDegreeCount = (graph->max_degree + BLOCK_SIZE_2_D - 1)/BLOCK_SIZE_2_D;

    num_iter = 0;

    dim3 dimReduceBlock(BLOCK_SIZE, 1, 1);
    dim3 dimReduceGrid(blockEdge1dCount, 1, 1);
    int reduceSmemSize = (BLOCK_SIZE <= 32) ? 2 * BLOCK_SIZE * sizeof(float) : BLOCK_SIZE * sizeof(float);

    dim3 dimInitMessageBuffer(BLOCK_SIZE_2_D, BLOCK_SIZE_2_D, 1);
    dim3 dimInitGrid(blockNodeCount, blockStateCount, 1);
    dim3 dimDegreeGrid(blockNodeCount, blockDegreeCount, 1);

    for(i = 0; i < max_iterations; i+= BATCH_SIZE){
        for(j = 0; j < BATCH_SIZE; ++j) {
            init_message_buffer_kernel<<<dimInitGrid, dimInitMessageBuffer>>>(message_buffer, node_states, node_num_vars, num_vertices);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            read_incoming_messages_kernel <<<dimDegreeGrid, dimInitMessageBuffer, reduceSmemSize>>>(message_buffer, previous_messages, dest_nodes_to_edges, num_edges, node_num_vars, num_vertices, is_pow_2, WARP_SIZE);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            send_message_for_node_kernel<<<dimDegreeGrid, dimInitMessageBuffer>>>(message_buffer, num_edges, edges_joint_probabilities, current_messages, src_nodes_to_edges, edges_x_dim, edges_y_dim, num_vertices);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            marginalize_node_kernel<<<dimDegreeGrid, dimInitMessageBuffer, reduceSmemSize>>>(node_num_vars, message_buffer, node_states, current_messages, dest_nodes_to_edges, num_vertices, num_edges, is_pow_2, WARP_SIZE);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));

            //swap pointers
            temp = current_messages;
            current_messages = previous_messages;
            previous_messages = temp;
            num_iter++;
        }
        calculate_delta_6<<<dimReduceGrid, dimReduceBlock, reduceSmemSize>>>(previous_messages, current_messages, delta, delta_array, edges_x_dim, num_edges, is_pow_2, WARP_SIZE);
        //calculate_delta<<<dimReduceGrid, dimReduceBlock, reduceSmemSize>>>(previous_messages, current_messages, delta, delta_array, edges_x_dim, num_edges);
        //calculate_delta_simple<<<dimReduceGrid, dimReduceBlock, reduceSmemSize>>>(previous_messages, current_messages, delta, delta_array, edges_x_dim, num_edges);
        check_cuda_kernel_return_code();
        CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
     //   printf("Current delta: %f\n", host_delta);

        if(host_delta < convergence || fabs(host_delta - previous_delta) < convergence){
            break;
        }
        previous_delta = host_delta;
    }

    // copy data back
    CUDA_CHECK_RETURN(cudaMemcpy(graph->node_states, node_states, sizeof(float) * MAX_STATES * num_vertices, cudaMemcpyDeviceToHost));
    CUDA_CHECK_RETURN(cudaMemcpy(graph->edges_messages, current_messages, sizeof(float) * MAX_STATES * num_edges, cudaMemcpyDeviceToHost));
    CUDA_CHECK_RETURN(cudaMemcpy(graph->last_edges_messages, previous_messages, sizeof(float) * MAX_STATES * num_edges, cudaMemcpyDeviceToHost));

    CUDA_CHECK_RETURN(cudaFree(dest_nodes_to_edges));
    CUDA_CHECK_RETURN(cudaFree(src_nodes_to_edges));

    CUDA_CHECK_RETURN(cudaFree(edges_x_dim));
    CUDA_CHECK_RETURN(cudaFree(edges_y_dim));

    CUDA_CHECK_RETURN(cudaFree(edges_joint_probabilities));

    CUDA_CHECK_RETURN(cudaFree(current_messages));
    CUDA_CHECK_RETURN(cudaFree(previous_messages));
    CUDA_CHECK_RETURN(cudaFree(message_buffer));

    CUDA_CHECK_RETURN(cudaFree(node_states));
    CUDA_CHECK_RETURN(cudaFree(node_num_vars));

    CUDA_CHECK_RETURN(cudaFree(delta));
    CUDA_CHECK_RETURN(cudaFree(delta_array));

    /*printf("After=====");
    print_nodes(graph);
    print_edges(graph);*/

    return num_iter;
}

void test_ast(const char * expr)
{
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;

    assert(yylex_init(&scanner) == 0);

    assert(scanner != NULL);
    assert(strlen(expr) > 0);

    state = yy_scan_string(expr, scanner);

    assert(yyparse(&expression, scanner) == 0);
    yy_delete_buffer(state, scanner);
    yylex_destroy(scanner);

    assert(expression != NULL);

    delete_expression(expression);
}

void test_file(const char * file_path)
{
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;
    FILE * in;

    assert(yylex_init(&scanner) == 0);

    in = fopen(file_path, "r");

    yyset_in(in, scanner);

    assert(yyparse(&expression, scanner) == 0);
    //yy_delete_buffer(state, scanner);
    yylex_destroy(scanner);

    fclose(in);

    assert(expression != NULL);

    delete_expression(expression);
}

void test_parse_file(char * file_name){
    unsigned int i;
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;
    FILE * in;
    Graph_t graph;
    clock_t start, end;
    float time_elapsed;

    assert(yylex_init(&scanner) == 0);

    in = fopen(file_name, "r");

    yyset_in(in, scanner);

    assert(yyparse(&expression, scanner) == 0);
    //yy_delete_buffer(state, scanner);
    yylex_destroy(scanner);

    fclose(in);

    assert(expression != NULL);

    graph = build_graph(expression);
    //print_nodes(graph);
    //print_edges(graph);

    set_up_src_nodes_to_edges(graph);
    set_up_dest_nodes_to_edges(graph);

    start = clock();
    init_levels_to_nodes(graph);
    //print_levels_to_nodes(graph);

    propagate_using_levels_start(graph);
    for(i = 1; i < graph->num_levels - 1; ++i){
        propagate_using_levels(graph, i);
    }
    reset_visited(graph);
    for(i = graph->num_levels - 1; i > 0; --i){
        propagate_using_levels(graph, i);
    }

    marginalize(graph);
    end = clock();

    time_elapsed = (float)(end - start) / CLOCKS_PER_SEC;
    printf("%s,regular,%d,%d,%f\n", file_name, graph->current_num_vertices, graph->current_num_edges, time_elapsed);

    //print_nodes(graph);

    assert(graph != NULL);

    delete_expression(expression);

    graph_destroy(graph);
}

void test_loopy_belief_propagation(char * file_name){
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;
    FILE * in;
    Graph_t graph;
    clock_t start, end;
    float time_elapsed;

    assert(yylex_init(&scanner) == 0);

    in = fopen(file_name, "r");

    yyset_in(in, scanner);

    assert(yyparse(&expression, scanner) == 0);
    //yy_delete_buffer(state, scanner);
    yylex_destroy(scanner);

    fclose(in);

    assert(expression != NULL);

    graph = build_graph(expression);
    assert(graph != NULL);
    //print_nodes(graph);
    //print_edges(graph);

    set_up_src_nodes_to_edges(graph);
    set_up_dest_nodes_to_edges(graph);

    start = clock();
    init_previous_edge(graph);

    loopy_propagate_until_cuda(graph, PRECISION, NUM_ITERATIONS);
    end = clock();

    time_elapsed = (float)(end - start)/CLOCKS_PER_SEC;
    //print_nodes(graph);
    printf("%s,loopy,%d,%d,%f\n", file_name, graph->current_num_vertices, graph->current_num_edges, time_elapsed);

    delete_expression(expression);

    graph_destroy(graph);
}

struct expression * parse_file(const char * file_name){
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;
    FILE * in;

    assert(yylex_init(&scanner) == 0);

    in = fopen(file_name, "r");

    yyset_in(in, scanner);

    assert(yyparse(&expression, scanner) == 0);
    //yy_delete_buffer(state, scanner);
    yylex_destroy(scanner);

    fclose(in);

    assert(expression != NULL);

    return expression;
}

void run_test_belief_propagation(struct expression * expression, const char * file_name){
    Graph_t graph;
    clock_t start, end;
    float time_elapsed;
    unsigned int i;

    graph = build_graph(expression);
    assert(graph != NULL);
    //print_nodes(graph);
    //print_edges(graph);

    set_up_src_nodes_to_edges(graph);
    set_up_dest_nodes_to_edges(graph);
    calculate_diameter(graph);

    start = clock();
    init_levels_to_nodes(graph);
    //print_levels_to_nodes(graph);

    propagate_using_levels_start(graph);
    for(i = 1; i < graph->num_levels - 1; ++i){
        propagate_using_levels(graph, i);
    }
    reset_visited(graph);
    for(i = graph->num_levels - 1; i > 0; --i){
        propagate_using_levels(graph, i);
    }

    marginalize(graph);
    end = clock();

    time_elapsed = (float)(end - start) / CLOCKS_PER_SEC;
    printf("%s,regular,%d,%d,%d,2,%f\n", file_name, graph->current_num_vertices, graph->current_num_edges, graph->diameter, time_elapsed);

    graph_destroy(graph);
}

void run_test_loopy_belief_propagation(struct expression * expression, const char * file_name, FILE * out){
    Graph_t graph;
    clock_t start, end;
    float time_elapsed;
    unsigned int num_iterations;

    graph = build_graph(expression);
    assert(graph != NULL);
    //print_nodes(graph);
    //print_edges(graph);

    set_up_src_nodes_to_edges(graph);
    set_up_dest_nodes_to_edges(graph);
    //calculate_diameter(graph);

    start = clock();
    init_previous_edge(graph);

    num_iterations = loopy_propagate_until_cuda(graph, PRECISION, NUM_ITERATIONS);
    end = clock();

    time_elapsed = (float)(end - start)/CLOCKS_PER_SEC;
    //print_nodes(graph);
    fprintf(out, "%s,loopy,%d,%d,%d,%d,%f\n", file_name, graph->current_num_vertices, graph->current_num_edges, graph->diameter, num_iterations, time_elapsed);
    fflush(out);

    graph_destroy(graph);
}

void run_tests_with_file(const char * file_name, unsigned int num_iterations, FILE * out){
    unsigned int i;
    struct expression * expr;

    expr = parse_file(file_name);
    for(i = 0; i < num_iterations; ++i){
        run_test_belief_propagation(expr, file_name);
    }

    for(i = 0; i < num_iterations; ++i){
        run_test_loopy_belief_propagation(expr, file_name, out);
    }

    delete_expression(expr);
}

void run_tests_with_xml_file(const char * file_name, unsigned int num_iterations, FILE * out){
    unsigned int i;
    struct expression * expr;

    expr = parse_xml_file(file_name);
    /*for(i = 0; i < num_iterations; ++i){
        run_test_belief_propagation(expr, file_name);
    }*/

    for(i = 0; i < num_iterations; ++i){
        run_test_loopy_belief_propagation(expr, file_name, out);
    }

    delete_expression(expr);
}

int main(void)
{
/*
	extern int yydebug;
	yydebug = 1;
/*
	struct expression * expression = NULL;
	const char test[] = "// Bayesian Network in the Interchange Format\n// Produced by BayesianNetworks package in JavaBayes\n// Output created Sun Nov 02 17:49:49 GMT+00:00 1997\n// Bayesian network \nnetwork \"Dog-Problem\" { //5 variables and 5 probability distributions\nproperty \"credal-set constant-density-bounded 1.1\" ;\n}variable  \"light-on\" { //2 values\ntype discrete[2] {  \"true\"  \"false\" };\nproperty \"position = (218, 195)\" ;\n}\nvariable  \"bowel-problem\" { //2 values\ntype discrete[2] {  \"true\"  \"false\" };\nproperty \"position = (335, 99)\" ;\n}";
	test_ast(test);

  	test_parse_file("dog.bif");
	test_parse_file("alarm.bif");

	test_parse_file("very_large/andes.bif");
	test_loopy_belief_propagation("very_large/andes.bif");

	test_parse_file("Diabetes.bif");
	test_loopy_belief_propagation("Diabetes.bif");
*/
	//test_loopy_belief_propagation("../benchmark_files/dog.bif");
	//test_loopy_belief_propagation("../benchmark_files/alarm.bif");

    //test_file("dog.bif");
    //test_file("alarm.bif");

    /*expression = read_file("alarm.bif");

    assert(expression != NULL);

    delete_expression(expression);*/

    FILE * out = fopen("cuda_kernels_benchmark.csv", "w");
    fprintf(out, "File Name,Propagation Type,Number of Nodes,Number of Edges,Diameter,Number of Iterations,BP Run Time(s)\n");
    fflush(out);

	/*run_tests_with_file("../benchmark_files/small/asia.bif", 1);
	run_tests_with_file("../benchmark_files/small/cancer.bif", 1);
	run_tests_with_file("../benchmark_files/small/earthquake.bif", 1);
	run_tests_with_file("../benchmark_files/small/sachs.bif", 1);
	run_tests_with_file("../benchmark_files/small/survey.bif", 1);
/*
	run_tests_with_file("../benchmark_files/medium/alarm.bif", 1);
	run_tests_with_file("../benchmark_files/medium/barley.bif", 1);
	//run_tests_with_file("../benchmark_files/medium/child.bif", 1);
	run_tests_with_file("../benchmark_files/medium/hailfinder.bif", 1);
	run_tests_with_file("../benchmark_files/medium/insurance.bif", 1);
	run_tests_with_file("../benchmark_files/medium/mildew.bif", 1);
	run_tests_with_file("../benchmark_files/medium/water.bif", 1);

	run_tests_with_file("../benchmark_files/large/hepar2.bif", 1);
	run_tests_with_file("../benchmark_files/large/win95pts.bif", 1);

    run_tests_with_file("../benchmark_files/very_large/andes.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/diabetes.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/link.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/munin1.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/munin2.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/munin3.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/munin4.bif", 1);
	//run_tests_with_file("../benchmark_files/very_large/munin.bif", 1);
	run_tests_with_file("../benchmark_files/very_large/pathfinder.bif", 1);
    run_tests_with_file("../benchmark_files/very_large/pigs.bif", 1);

    run_tests_with_xml_file("../benchmark_files/xml/bf_1000_2000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_1000_2000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_1000_2000_3.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_2000_4000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_2000_4000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_2000_4000_3.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_5000_10000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_5000_10000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_5000_10000_3.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_10000_20000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_10000_20000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_10000_20000_3.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_12000_24000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_12000_24000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_12000_24000_3.xml", 1);*/

    /*run_tests_with_xml_file("../benchmark_files/xml/bf_15000_30000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_15000_30000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_15000_30000_3.xml", 1);

    run_tests_with_xml_file("../benchmark_files/xml/bf_20000_40000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_20000_40000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_20000_40000_3.xml", 1);

    run_tests_with_xml_file("../benchmark_files/xml/bf_25000_50000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_25000_50000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_25000_50000_3.xml", 1);

    run_tests_with_xml_file("../benchmark_files/xml/bf_30000_60000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_30000_60000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_30000_60000_3.xml", 1);*/

    /*run_tests_with_xml_file("../benchmark_files/xml/bf_40000_80000_1.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_40000_80000_2.xml", 1);
    run_tests_with_xml_file("../benchmark_files/xml/bf_40000_80000_3.xml", 1);

    run_tests_with_xml_file("../benchmark_files/xml/bf_80000_160000_2.xml", 1);*/

    run_tests_with_xml_file("../benchmark_files/xml2/10_20.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/100_200.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/1000_2000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/10000_20000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/100000_200000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/200000_400000.xml", 1, out);
    //run_tests_with_xml_file("../benchmark_files/xml2/300000_600000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/400000_800000.xml", 1, out);
    //run_tests_with_xml_file("../benchmark_files/xml2/500000_1000000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/600000_1200000.xml", 1, out);
    //run_tests_with_xml_file("../benchmark_files/xml2/700000_1400000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/800000_1600000.xml", 1, out);
    //run_tests_with_xml_file("../benchmark_files/xml2/900000_1800000.xml", 1, out);
    run_tests_with_xml_file("../benchmark_files/xml2/1000000_2000000.xml", 1, out);
    //run_tests_with_xml_file("../benchmark_files/xml2/10000000_20000000.xml", 1, out);

    return 0;
}


/**
 * Check the return value of the CUDA runtime API call and exit
 * the application if the call has failed.
 */
static void CheckCudaErrorAux (const char *file, unsigned int line, const char *statement, cudaError_t err)
{
    if (err == cudaSuccess)
        return;
    printf("%s returned %s (%d) at %s:%d\n", statement, cudaGetErrorString(err), err, file, line);
    exit (1);
}
