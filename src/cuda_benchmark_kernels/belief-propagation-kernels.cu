#include "belief-propagation-kernels.hpp"

__global__
void init_message_buffer_kernel(struct belief *message_buffer,
                                struct belief *node_states,
                                unsigned int *node_num_vars,
                                unsigned int num_nodes){
    unsigned int node_index, state_index, num_variables;

    for(node_index = blockIdx.x*blockDim.x + threadIdx.x; node_index < num_nodes; node_index += blockDim.x * gridDim.x){
        num_variables = node_num_vars[node_index];

        for(state_index = blockIdx.y*blockDim.y + threadIdx.y; state_index < num_variables; state_index += blockDim.y * gridDim.y){
            message_buffer[node_index].data[state_index] = node_states[node_index].data[state_index];
        }
    }
}

__device__
void combine_message_cuda(struct belief *dest, struct belief *edge_messages, unsigned int length, unsigned int node_index,
                          unsigned int edge_offset, unsigned int num_edges, char n_is_pow_2, unsigned int warp_size){
    __shared__ float shared_dest[BLOCK_SIZE_3_D_Z];
    __shared__ float shared_src[BLOCK_SIZE_3_D_Z];
    unsigned int index = threadIdx.z;

    if(index < length && edge_offset < num_edges){
        shared_dest[index] = dest[node_index].data[index];
        shared_src[index] = edge_messages[edge_offset].data[index];
        __syncthreads();

        dest[node_index].data[index] = shared_dest[index] * shared_src[index];
    }
}
__global__
void read_incoming_messages_kernel(struct belief *message_buffer, struct belief *previous_messages,
                                   unsigned int * dest_node_to_edges_nodes,
                                   unsigned int * dest_node_to_edges_edges,
                                   unsigned int current_num_edges,
                                   unsigned int *node_num_vars, unsigned int num_vertices,
                                   char n_is_pow_2, unsigned int warp_size){
    unsigned int node_index, edge_index, start_index, end_index, diff_index, tmp_index, num_variables;


    edge_index = blockIdx.y*blockDim.y + threadIdx.y;

    for(node_index = blockIdx.x*blockDim.x + threadIdx.x; node_index < num_vertices; node_index += blockDim.x * gridDim.x) {
        num_variables = node_num_vars[node_index];

        start_index = dest_node_to_edges_nodes[node_index];
        if (node_index + 1 >= num_vertices) {
            end_index = current_num_edges;
        } else {
            end_index = dest_node_to_edges_nodes[node_index + 1];
        }
        diff_index = end_index - start_index;
        if (edge_index < diff_index) {
            tmp_index = dest_node_to_edges_edges[edge_index + start_index];
            combine_message_cuda(message_buffer, previous_messages, num_variables, node_index,
                                 tmp_index, current_num_edges, n_is_pow_2, warp_size);
        }
    }
}

__device__
void send_message_for_edge_cuda(struct belief * message_buffer, unsigned int edge_index, unsigned int node_index,
                                struct joint_probability * joint_probabilities,
                                struct belief * edge_messages){
    unsigned int i, j, num_src, num_dest;
    float sum;
    struct joint_probability joint_probability;
    __shared__ float partial_sums[BLOCK_SIZE * MAX_STATES];

    joint_probability = joint_probabilities[edge_index];

    num_src = joint_probability.dim_x;
    num_dest = joint_probability.dim_y;

    sum = 0.0;
    for(i = 0; i < num_src; ++i){
        partial_sums[threadIdx.x * MAX_STATES + i] = 0.0;
        for(j = 0; j < num_dest; ++j){
            partial_sums[threadIdx.x * MAX_STATES + i] += joint_probability.data[i][j] * message_buffer[node_index].data[j];
        }
        sum += partial_sums[threadIdx.x * MAX_STATES + i];
    }
    if(sum <= 0.0){
        sum = 1.0;
    }
    for(i = 0; i < num_src; ++i){
        edge_messages[edge_index].data[i] = partial_sums[threadIdx.x * MAX_STATES + i] / sum;
    }
}

__global__
void send_message_for_node_kernel(struct belief *message_buffer, unsigned int current_num_edges,
                                  struct joint_probability *joint_probabilities, struct belief *current_edge_messages,
                                  unsigned int * src_node_to_edges_nodes,
                                  unsigned int * src_node_to_edges_edges,
                                  unsigned int num_vertices){
    unsigned int node_index, edge_index, start_index, end_index, diff_index;

    edge_index = blockIdx.y*blockDim.y + threadIdx.y;

    for(node_index = blockIdx.x*blockDim.x + threadIdx.x; node_index < num_vertices; node_index += blockDim.x * gridDim.x){
        start_index = src_node_to_edges_nodes[node_index];
        if(node_index + 1 >= num_vertices){
            end_index = current_num_edges;
        }
        else{
            end_index = src_node_to_edges_nodes[node_index + 1];
        }
        diff_index = end_index - start_index;
        if (edge_index < diff_index) {
            edge_index = src_node_to_edges_edges[edge_index + start_index];
            send_message_for_edge_cuda(message_buffer, edge_index, node_index, joint_probabilities, current_edge_messages);
        }
    }
}

__global__
void marginalize_node_combine_kernel(unsigned int * node_num_vars, struct belief *message_buffer, struct belief *node_states,
                             struct belief *current_edges_messages,
                             unsigned int * dest_node_to_edges_nodes,
                             unsigned int * dest_node_to_edges_edges,
                             unsigned int num_vertices,
                             unsigned int num_edges, char n_is_pow_2, unsigned int warp_size){
    unsigned int node_index, edge_index, temp_edge_index, num_variables, start_index, end_index, diff_index;

    edge_index =  blockIdx.y*blockDim.y + threadIdx.y;


    for(node_index = blockIdx.x*blockDim.x + threadIdx.x; node_index < num_vertices; node_index += blockDim.x * gridDim.x) {
        num_variables = node_num_vars[node_index];
        if(edge_index < num_variables){
            message_buffer[node_index].data[edge_index] = 1.0;
        }
        start_index = dest_node_to_edges_nodes[node_index];
        if(node_index + 1 >= num_vertices){
            end_index = num_edges;
        }
        else{
            end_index = dest_node_to_edges_nodes[node_index + 1];
        }
        diff_index = end_index - start_index;
        if(edge_index < diff_index){
            temp_edge_index = dest_node_to_edges_edges[edge_index + start_index];

            combine_message_cuda(message_buffer, current_edges_messages, num_variables, node_index, temp_edge_index, num_edges, n_is_pow_2, warp_size);
        }

    }
}

__global__
void marginalize_sum_node_kernel(unsigned int * node_num_vars, struct belief * message_buffer, struct belief * node_states,
                             struct belief * current_edges_messages,
                             unsigned int * dest_node_to_edges_nodes,
                             unsigned int * dest_node_to_edges_edges,
                             unsigned int num_vertices,
                             unsigned int num_edges, char n_is_pow_2, unsigned int warp_size){
    unsigned int node_index, edge_index, num_variables;
    __shared__ float sum[BLOCK_SIZE_2_D_X];
    __shared__ float shared_message_buffer[BLOCK_SIZE_2_D_X][BLOCK_SIZE_2_D_Y];

    edge_index =  blockIdx.y*blockDim.y + threadIdx.y;

    for(node_index = blockIdx.x*blockDim.x + threadIdx.x; node_index < num_vertices; node_index += blockDim.x * gridDim.x) {
        num_variables = node_num_vars[node_index];
        if(edge_index < num_variables) {
            if (edge_index == 0) {
                sum[threadIdx.x] = 0.0;
            }
            shared_message_buffer[threadIdx.x][threadIdx.y] *= message_buffer[node_index].data[edge_index];
            __syncthreads();

            atomicAdd(&sum[threadIdx.x], shared_message_buffer[threadIdx.x][threadIdx.y]);
            __syncthreads();
            if (threadIdx.y == 0 && sum[threadIdx.x] <= 0.0) {
                sum[threadIdx.x] = 1.0;
            }
            __syncthreads();
            node_states[node_index].data[edge_index] = shared_message_buffer[threadIdx.x][threadIdx.y] / sum[threadIdx.x];
        }
    }

}

__device__
float calculate_local_delta(unsigned int i, struct belief * previous_messages, struct belief * current_messages, unsigned int * edges_x_dim){
    float delta, diff;
    unsigned int k;

    delta = 0.0;

    for(k = 0; k < edges_x_dim[i]; ++k){
        diff = previous_messages[i].data[k] - current_messages[i].data[k];
        if(diff != diff){
            diff = 0.0;
        }
        delta += fabs(diff);
    }

    return delta;
}

__global__
void calculate_delta(struct belief * previous_messages, struct belief * current_messages, float * delta, float * delta_array, unsigned int * edges_x_dim, unsigned int num_edges){
    extern __shared__ float shared_delta[];
    unsigned int tid, idx, i, s;

    tid = threadIdx.x;
    i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;

    for(idx = blockIdx.x*blockDim.x + threadIdx.x; idx < num_edges; idx += blockDim.x * gridDim.x){
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
void calculate_delta_6(struct belief *previous_messages, struct belief *current_messages, float * delta, float * delta_array,
                       unsigned int * edges_x_dim,
                       unsigned int num_edges, char n_is_pow_2, unsigned int warp_size) {
    extern __shared__ float shared_delta[];

    unsigned int offset;
    // perform first level of reduce
    // reading from global memory, writing to shared memory
    unsigned int idx;
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x * 2 + threadIdx.x;
    unsigned int grid_size = blockDim.x * 2 * gridDim.x;

    for(idx = blockIdx.x*blockDim.x + threadIdx.x; idx < num_edges; idx += blockDim.x * gridDim.x){
        delta_array[idx] = calculate_local_delta(idx, previous_messages, current_messages, edges_x_dim);
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
void calculate_delta_simple(struct belief * previous_messages, struct belief * current_messages,
                            float * delta, float * delta_array, unsigned int * edges_x_dim,
                            unsigned int num_edges) {
    extern __shared__ float shared_delta[];
    unsigned int tid, idx, i, s;

    tid = threadIdx.x;

    for(idx = blockIdx.x*blockDim.x + threadIdx.x; idx < num_edges; idx += blockDim.x * gridDim.x){
        delta_array[idx] = calculate_local_delta(idx, previous_messages, current_messages, edges_x_dim);
    }
    __syncthreads();

    idx = blockIdx.x * blockDim.x + threadIdx.x;

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

void check_cuda_kernel_return_code(){
    cudaError_t err;

    err = cudaGetLastError();
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: %s\n", cudaGetErrorString(err));
        exit(-1);
    }
}

unsigned int loopy_propagate_until_cuda_kernels(Graph_t graph, float convergence, unsigned int max_iterations){
    unsigned int i, j, num_iter, num_vertices, num_edges;
    float * delta;
    float * delta_array;
    float previous_delta, host_delta;
    char is_pow_2;

    struct joint_probability * edges_joint_probabilities;

    struct belief * message_buffer;

    struct belief * current_messages;
    struct belief * previous_messages;
    struct belief * temp;

    unsigned int * edges_x_dim;
    unsigned int * edges_y_dim;

    unsigned int * src_nodes_to_edges_nodes;
    unsigned int * src_nodes_to_edges_edges;
    unsigned int * dest_nodes_to_edges_nodes;
    unsigned int * dest_nodes_to_edges_edges;

    struct belief * node_states;
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

    CUDA_CHECK_RETURN(cudaMalloc((void **)&edges_joint_probabilities, sizeof(struct joint_probability) * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&dest_nodes_to_edges_nodes, sizeof(unsigned int) * graph->current_num_vertices));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&dest_nodes_to_edges_edges, sizeof(unsigned int) * graph->current_num_edges));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&src_nodes_to_edges_nodes, sizeof(unsigned int) * graph->current_num_vertices));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&src_nodes_to_edges_edges, sizeof(unsigned int) * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&current_messages, sizeof(struct belief) * graph->current_num_edges));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&previous_messages, sizeof(struct belief) * graph->current_num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&node_states, sizeof(struct belief) * graph->current_num_vertices));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&node_num_vars, sizeof(unsigned int) * graph->current_num_vertices));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&delta, sizeof(float)));
    CUDA_CHECK_RETURN(cudaMalloc((void **)&delta_array, sizeof(float) * num_edges));

    CUDA_CHECK_RETURN(cudaMalloc((void **)&message_buffer, sizeof(struct belief) * num_vertices));

    // copy data
    CUDA_CHECK_RETURN(cudaMemcpy(edges_joint_probabilities, graph->edges_joint_probabilities, sizeof(struct joint_probability) * graph->current_num_edges, cudaMemcpyHostToDevice ));

    CUDA_CHECK_RETURN(cudaMemcpy(current_messages, graph->edges_messages, sizeof(struct belief) * graph->current_num_edges, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(current_messages, graph->last_edges_messages, sizeof(struct belief) * graph->current_num_edges, cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(node_num_vars, graph->node_num_vars, sizeof(unsigned int) * graph->current_num_vertices, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(node_states, graph->node_states, sizeof(struct belief) * graph->current_num_vertices, cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(dest_nodes_to_edges_nodes, graph->dest_nodes_to_edges_node_list, sizeof(unsigned int) * graph->current_num_vertices, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(dest_nodes_to_edges_edges, graph->dest_nodes_to_edges_edge_list, sizeof(unsigned int) * graph->current_num_edges, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(src_nodes_to_edges_nodes, graph->src_nodes_to_edges_node_list, sizeof(unsigned int) * graph->current_num_vertices, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(src_nodes_to_edges_edges, graph->src_nodes_to_edges_edge_list, sizeof(unsigned int) * graph->current_num_edges, cudaMemcpyHostToDevice));

    CUDA_CHECK_RETURN(cudaMemcpy(edges_x_dim, graph->edges_x_dim, sizeof(unsigned int) * num_edges, cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(edges_y_dim, graph->edges_y_dim, sizeof(unsigned int) * num_edges, cudaMemcpyHostToDevice));


    const int blockEdge1dCount = (num_edges + BLOCK_SIZE - 1)/ BLOCK_SIZE;

    const int blockNodeCount = (num_vertices + BLOCK_SIZE_2_D_X - 1)/BLOCK_SIZE_2_D_X;
    const int blockStateCount = (MAX_STATES + BLOCK_SIZE_2_D_Y - 1)/BLOCK_SIZE_2_D_Y;
    const int blockDegreeCount = (graph->max_degree + BLOCK_SIZE_2_D_Y - 1)/BLOCK_SIZE_2_D_Y;

    const int blockMessageNodeCount = (num_vertices + BLOCK_SIZE_3_D_X - 1)/BLOCK_SIZE_3_D_X;
    const int blockMessageDegreeCount = ( graph->max_degree + BLOCK_SIZE_3_D_Y - 1)/BLOCK_SIZE_3_D_Y;
    const int blockMessageStateCount = ( MAX_STATES + BLOCK_SIZE_3_D_Z - 1)/BLOCK_SIZE_3_D_Z;

    num_iter = 0;

    dim3 dimReduceBlock(BLOCK_SIZE, 1, 1);
    dim3 dimReduceGrid(blockEdge1dCount, 1, 1);
    int reduceSmemSize = (BLOCK_SIZE <= 32) ? 2 * BLOCK_SIZE * sizeof(float) : BLOCK_SIZE * sizeof(float);

    dim3 dimInitMessageBuffer(BLOCK_SIZE_2_D_X, BLOCK_SIZE_2_D_Y, 1);
    dim3 dimInitGrid(blockNodeCount, blockStateCount, 1);
    dim3 dimDegreeGrid(blockNodeCount, blockDegreeCount, 1);
    int reduce2DSmemSize = (BLOCK_SIZE_2_D_Y <= 32) ? 2 * BLOCK_SIZE_2_D_Y * sizeof(float) : BLOCK_SIZE_2_D_Y * sizeof(float);

    dim3 dimMessagesBuffer(BLOCK_SIZE_3_D_X, BLOCK_SIZE_3_D_Y, BLOCK_SIZE_3_D_Z);
    dim3 dimMessagesGrid(blockMessageNodeCount, blockMessageDegreeCount, blockMessageStateCount);

    for(i = 0; i < max_iterations; i+= BATCH_SIZE){
        for(j = 0; j < BATCH_SIZE; ++j) {
            init_message_buffer_kernel<<<dimInitGrid, dimInitMessageBuffer>>>(message_buffer, node_states, node_num_vars, num_vertices);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            read_incoming_messages_kernel <<<dimMessagesGrid, dimMessagesBuffer>>>(message_buffer, previous_messages, dest_nodes_to_edges_nodes, dest_nodes_to_edges_edges, num_edges, node_num_vars, num_vertices, is_pow_2, WARP_SIZE);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            send_message_for_node_kernel<<<dimInitGrid, dimInitMessageBuffer>>>(message_buffer, num_edges, edges_joint_probabilities, current_messages, src_nodes_to_edges_nodes, src_nodes_to_edges_edges, num_vertices);
            check_cuda_kernel_return_code();
            //CUDA_CHECK_RETURN(cudaMemcpy(&host_delta, delta, sizeof(float), cudaMemcpyDeviceToHost));
            marginalize_node_combine_kernel<<<dimMessagesGrid, dimMessagesBuffer>>>(node_num_vars, message_buffer, node_states, current_messages, dest_nodes_to_edges_nodes, dest_nodes_to_edges_edges, num_vertices, num_edges, is_pow_2, WARP_SIZE);
            check_cuda_kernel_return_code();
            marginalize_sum_node_kernel<<<dimInitGrid, dimInitMessageBuffer>>>(node_num_vars, message_buffer, node_states, current_messages, dest_nodes_to_edges_nodes, dest_nodes_to_edges_edges, num_vertices, num_edges, is_pow_2, WARP_SIZE);
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
    CUDA_CHECK_RETURN(cudaMemcpy(graph->node_states, node_states, sizeof(struct belief) * num_vertices, cudaMemcpyDeviceToHost));
    CUDA_CHECK_RETURN(cudaMemcpy(graph->edges_messages, current_messages, sizeof(struct belief) * num_edges, cudaMemcpyDeviceToHost));
    CUDA_CHECK_RETURN(cudaMemcpy(graph->last_edges_messages, previous_messages, sizeof(struct belief) * num_edges, cudaMemcpyDeviceToHost));

    CUDA_CHECK_RETURN(cudaFree(dest_nodes_to_edges_nodes));
    CUDA_CHECK_RETURN(cudaFree(dest_nodes_to_edges_edges));
    CUDA_CHECK_RETURN(cudaFree(src_nodes_to_edges_nodes));
    CUDA_CHECK_RETURN(cudaFree(src_nodes_to_edges_edges));

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

void test_loopy_belief_propagation_kernels(char * file_name){
    struct expression * expression;
    yyscan_t scanner;
    YY_BUFFER_STATE state;
    FILE * in;
    Graph_t graph;
    clock_t start, end;
    double time_elapsed;

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

    loopy_propagate_until_cuda_kernels(graph, PRECISION, NUM_ITERATIONS);
    end = clock();

    time_elapsed = (double)(end - start)/CLOCKS_PER_SEC;
    //print_nodes(graph);
    printf("%s,loopy,%d,%d,%lf\n", file_name, graph->current_num_vertices, graph->current_num_edges, time_elapsed);

    delete_expression(expression);

    graph_destroy(graph);
}

void run_test_loopy_belief_propagation_kernels(struct expression * expression, const char * file_name, FILE * out){
    Graph_t graph;
    clock_t start, end;
    double time_elapsed;
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

    num_iterations = loopy_propagate_until_cuda_kernels(graph, PRECISION, NUM_ITERATIONS);
    end = clock();

    time_elapsed = (double)(end - start)/CLOCKS_PER_SEC;
    //print_nodes(graph);
    fprintf(out, "%s,loopy,%d,%d,%d,%d,%lf\n", file_name, graph->current_num_vertices, graph->current_num_edges, graph->diameter, num_iterations, time_elapsed);
    fflush(out);

    graph_destroy(graph);
}


void run_test_loopy_belief_propagation_xml_file_kernels(const char * file_name, FILE * out){
    Graph_t graph;
    clock_t start, end;
    double time_elapsed;
    unsigned int num_iterations;

    graph = parse_xml_file(file_name);
    assert(graph != NULL);
    //print_nodes(graph);
    //print_edges(graph);

    set_up_src_nodes_to_edges(graph);
    set_up_dest_nodes_to_edges(graph);
    //calculate_diameter(graph);

    start = clock();
    init_previous_edge(graph);

    num_iterations = loopy_propagate_until_cuda_kernels(graph, PRECISION, NUM_ITERATIONS);
    end = clock();

    time_elapsed = (double)(end - start)/CLOCKS_PER_SEC;
    //print_nodes(graph);
    fprintf(out, "%s,loopy,%d,%d,%d,%d,%lf\n", file_name, graph->current_num_vertices, graph->current_num_edges, graph->diameter, num_iterations, time_elapsed);
    fflush(out);

    graph_destroy(graph);
}


/**
 * Check the return value of the CUDA runtime API call and exit
 * the application if the call has failed.
 */
void CheckCudaErrorAux (const char *file, unsigned int line, const char *statement, cudaError_t err)
{
    if (err == cudaSuccess)
        return;
    printf("%s returned %s (%d) at %s:%d\n", statement, cudaGetErrorString(err), err, file, line);
    exit (1);
}

