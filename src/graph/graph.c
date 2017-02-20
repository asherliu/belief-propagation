#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "graph.h"

Graph_t
create_graph(int num_vertices, int num_edges)
{
	Graph_t g;

	g = (Graph_t)malloc(sizeof(struct graph));
	assert(g);
	g->edges = (Edge_t)malloc(sizeof(struct edge) * num_edges);
	assert(g->edges);
	g->prev_edges = (Edge_t)malloc(sizeof(struct edge) * num_edges);
	assert(g->prev_edges);
	g->nodes = (Node_t)malloc(sizeof(struct node) * num_vertices);
	assert(g->nodes);
	g->src_nodes_to_edges = (int *)malloc(sizeof(int) * (num_vertices + num_edges));
	assert(g->src_nodes_to_edges);
	g->dest_nodes_to_edges = (int *)malloc(sizeof(int) * (num_vertices + num_edges));
	assert(g->dest_nodes_to_edges);
	g->node_names = (char *)malloc(sizeof(char) * CHAR_BUFFER_SIZE * num_vertices);
	assert(g->node_names);
	g->forward_queue = (int *)malloc(sizeof(int) * num_vertices);
	assert(g->forward_queue);
	g->backward_queue = (int *)malloc(sizeof(int) * num_vertices);
	assert(g->backward_queue);
	g->leaf_node_queue = (int *)malloc(sizeof(int) * num_vertices);
	assert(g->leaf_node_queue);
	g->visited = (char *)calloc(sizeof(char), (size_t)num_vertices);
	assert(g->visited);
	g->observed_nodes = (char *)calloc(sizeof(char), (size_t)num_vertices);
	assert(g->observed_nodes);
	g->variable_names = (char *)calloc(sizeof(char), (size_t)num_vertices * CHAR_BUFFER_SIZE * MAX_STATES);
	assert(g->variable_names);
	g->forward_queue_start = 0;
	g->forward_queue_end = 0;
	g->backward_queue_start = 0;
	g->backward_queue_end = 0;
	g->leaf_node_queue_start = 0;
	g->leaf_node_queue_end = 0;
	g->total_num_vertices = num_vertices;
	g->total_num_edges = num_edges;
	g->current_num_vertices = 0;
	g->current_num_edges = 0;
	g->previous = &g->prev_edges;
	g->current = &g->edges;
	return g;
}

void graph_add_node(Graph_t g, int num_variables, const char * name) {
	int node_index;

	node_index = g->current_num_vertices;

	initialize_node(&g->nodes[node_index], node_index, num_variables);
	strncpy(&g->node_names[node_index * CHAR_BUFFER_SIZE], name, CHAR_BUFFER_SIZE);

	g->current_num_vertices += 1;
}

void graph_add_and_set_node_state(Graph_t g, int num_variables, const char * name, double * state){
	int node_index;

	node_index = g->current_num_vertices;

	g->observed_nodes[node_index] = 1;
	graph_add_node(g, num_variables, name);
	node_set_state(&g->nodes[node_index], num_variables, state);
}

void graph_set_node_state(Graph_t g, int node_index, int num_states, double * state){
	Node_t node;

	assert(node_index < g->current_num_vertices);

	node = &g->nodes[node_index];

	assert(num_states <= node->num_variables);

	g->observed_nodes[node_index] = 1;

	node_set_state(node, num_states, state);
}

void graph_add_edge(Graph_t graph, int src_index, int dest_index, int dim_x, int dim_y, double ** joint_probabilities) {
	int edge_index;

	edge_index = graph->current_num_edges;

	assert(graph->nodes[src_index].num_variables == dim_x);
	assert(graph->nodes[dest_index].num_variables == dim_y);


	init_edge(&graph->edges[edge_index], edge_index, src_index, dest_index, dim_x, dim_y, joint_probabilities);
	init_edge(&graph->prev_edges[edge_index], edge_index, src_index, dest_index, dim_x, dim_y, joint_probabilities);

	graph->current_num_edges += 1;
}

void set_up_src_nodes_to_edges(Graph_t graph){
	int i, j, edge_index, num_vertices, num_edges;
	Edge_t edge = NULL;

	assert(graph->current_num_vertices == graph->total_num_vertices);
	assert(graph->current_num_edges <= graph->total_num_edges);

	edge_index = graph->total_num_vertices;

	num_vertices = graph->total_num_vertices;
	num_edges = graph->current_num_edges;

	for(i = 0; i < num_vertices; ++i){
		graph->src_nodes_to_edges[i] = edge_index;
		for(j = 0; j < num_edges; ++j){
			edge = &graph->edges[j];

			if(edge->src_index == i){
				graph->src_nodes_to_edges[edge_index] = edge->edge_index;
				edge_index += 1;
			}
		}
	}
}

void set_up_dest_nodes_to_edges(Graph_t graph){
	int i, j, edge_index, num_vertices, num_edges;
	Edge_t edge = NULL;
	Node_t node = NULL;

	assert(graph->current_num_vertices == graph->total_num_vertices);
	assert(graph->current_num_edges <= graph->total_num_edges);

	edge_index = graph->total_num_vertices;

	num_vertices = graph->total_num_vertices;
	num_edges = graph->current_num_edges;

	for(i = 0; i < num_vertices; ++i){
		graph->dest_nodes_to_edges[i] = edge_index;
		for(j = 0; j < num_edges; ++j){
			edge = &graph->edges[j];

			if(edge->dest_index == i){
				graph->dest_nodes_to_edges[edge_index] = edge->edge_index;
				edge_index += 1;
			}
		}

	}
}

int graph_vertex_count(Graph_t g) {
	return g->current_num_vertices;
}

int graph_edge_count(Graph_t g) {
	return g->current_num_edges;
}

void graph_destroy(Graph_t g) {
	free(g->edges);
	free(g->prev_edges);
	free(g->nodes);
	free(g->src_nodes_to_edges);
	free(g->dest_nodes_to_edges);
	free(g->node_names);
	free(g->forward_queue);
	free(g->backward_queue);
	free(g->leaf_node_queue);
	free(g->visited);
	free(g->observed_nodes);
	free(g->variable_names);
	free(g);
}

void fill_forward_buffer_with_leaf_nodes(Graph_t g, int max_count){
	int i, start_index, end_index, num_nodes;
	int * dest_nodes_to_edges;

	num_nodes = g->current_num_vertices;
	dest_nodes_to_edges = g->dest_nodes_to_edges;

	for(i = 0; i < num_nodes; ++i){
		start_index = dest_nodes_to_edges[i];
		if(i + 1 == num_nodes){
			end_index = num_nodes + g->current_num_edges;
		}
		else
		{
			end_index = dest_nodes_to_edges[i+1];
		}
		if(end_index - start_index <= max_count){
			push_node(i, g->leaf_node_queue, &g->leaf_node_queue_start, &g->leaf_node_queue_end, g->current_num_vertices);
		}
	}
}


void push_node(int n, int * queue, int * start_index, int * end_index, int mod){
	int i;

	for(i = *start_index; i < *end_index; ++i){
		if(queue[i % mod] == n){

			return;
		}
	}

	queue[*end_index % mod] = n;
	*end_index += 1;
}

int pop_node(int * queue, int * start_index, int * end_index, int mod){
	int i, n;
	if(*start_index == *end_index){
		return -1;
	}
	n = queue[*start_index % mod];
	*start_index += 1;
	return n;
}

void send_from_leaf_nodes(Graph_t g) {
	int i, j, node_index, start_index, edge_index, end_index, num_vertices;
	Node_t node;
	Edge_t edge;

	num_vertices = g->current_num_vertices;

	fill_forward_buffer_with_leaf_nodes(g, 1);

	while(g->leaf_node_queue_start != g->leaf_node_queue_end){
		node_index = pop_node(g->leaf_node_queue, &g->leaf_node_queue_start, &g->leaf_node_queue_end, g->current_num_vertices);
		node = &g->nodes[node_index];
		//set as visited
		g->visited[node_index] = 1;

		//send messages
		start_index = g->src_nodes_to_edges[node_index];
		if(node_index + 1 == num_vertices){
			end_index = num_vertices + g->current_num_edges;
		}
		else {
			end_index = g->src_nodes_to_edges[node_index + 1];
		}
		for(i = start_index; i < end_index; ++i){
			g->visited[node_index] = 1;
			edge_index = g->src_nodes_to_edges[i];
			edge = &g->edges[edge_index];
			/*printf("sending message on edge\n");
			print_edge(g, edge_index);
			printf("message: [");
			for(j = 0; j < node->num_variables; ++j){
				printf("%.6lf\t", node->states[j]);
			}
			printf("]\n");*/
			send_message(edge, node->states);
			push_node(edge->dest_index, g->forward_queue, &g->forward_queue_start, &g->forward_queue_end, g->current_num_vertices);
		}
	}
}

void propagate(Graph_t g, int * src_queue, int * src_queue_start, int * src_queue_end, int * dest_queue, int * dest_queue_start, int * dest_queue_end){
	int current_node_index;

	while(*src_queue_start != *src_queue_end){
		current_node_index = pop_node(src_queue, src_queue_start, src_queue_end, g->current_num_vertices);
		//printf("Visiting node:\n");
		//print_node(g, current_node_index);
		propagate_node(g, current_node_index, src_queue, src_queue_start, src_queue_end, dest_queue, dest_queue_start, dest_queue_end);
	}
	//printf("All done\n");
}

static void combine_message(double * dest, Edge_t src_edge, int length){
	int i;
	double * src;

	src = src_edge->message;
	for(i = 0; i < length; ++i){
		if(src[i] <= 0.0){
			continue;
		}
		dest[i] = dest[i] * src[i];
	}
}

void propagate_node(Graph_t g, int current_node_index, int * src_queue, int * src_queue_start, int * src_queue_end, int * dest_queue, int * dest_queue_start, int * dest_queue_end){
	double message_buffer[MAX_STATES];
	int i, j, num_variables, start_index, end_index, num_vertices, num_sent, edge_index;
	Node_t node;
	Edge_t edge;
	int * dest_nodes_to_edges;
	int * src_nodes_to_edges;

	node = &g->nodes[current_node_index];
	num_variables = node->num_variables;

	// mark as visited
	g->visited[current_node_index] = 1;

	num_vertices = g->current_num_vertices;
	dest_nodes_to_edges = g->dest_nodes_to_edges;
	src_nodes_to_edges = g->src_nodes_to_edges;

	// init buffer
	for(i = 0; i < num_variables; ++i){
		message_buffer[i] = 1.0;
	}

	// get the edges feeding into this node
	start_index = dest_nodes_to_edges[current_node_index];
	if(current_node_index + 1 == num_vertices){
		end_index = num_vertices + g->current_num_edges;
	}
	else{
		end_index = dest_nodes_to_edges[current_node_index + 1];
	}
	for(i = start_index; i < end_index; ++i){
		edge_index = dest_nodes_to_edges[i];
		edge = &g->edges[edge_index];

		combine_message(message_buffer, edge, num_variables);
	}

	//send message
	start_index = src_nodes_to_edges[current_node_index];
	if(current_node_index + 1 == num_vertices){
		end_index = num_vertices + g->current_num_edges;
	}
	else {
		end_index = src_nodes_to_edges[current_node_index + 1];
	}

	num_sent = 0;

	for(i = start_index; i < end_index; ++i){
		edge_index = src_nodes_to_edges[i];
		edge = &g->edges[edge_index];
		//ensure node hasn't been visited yet
		if(g->visited[edge->dest_index] == 0){
			/*printf("sending message on edge\n");
			print_edge(g, edge_index);
			printf("message: [");
			for(j = 0; j < num_variables; ++j){
				printf("%.6lf\t", message_buffer[j]);
			}
			printf("]\n");*/
			send_message(edge, message_buffer);
			push_node(edge->dest_index, src_queue, src_queue_start, src_queue_end, g->current_num_vertices);
			num_sent += 1;
		}
	}

	if(num_sent == 0){
		push_node(current_node_index, dest_queue, dest_queue_start, dest_queue_end, g->current_num_vertices);
	}
}

static void marginalize_node(Graph_t g, int node_index, Edge_t edges){
	int i, num_variables, start_index, end_index, edge_index;
	char has_incoming;
	Edge_t edge;
	Node_t node;
	double sum;

	int * dest_nodes_to_edges;

	dest_nodes_to_edges = g->dest_nodes_to_edges;

	has_incoming = 0;

	node = &g->nodes[node_index];
	num_variables = node->num_variables;

	double new_message[MAX_STATES];
	for(i = 0; i < num_variables; ++i){
		new_message[i] = 1.0;
	}

	has_incoming = 0;

	start_index = dest_nodes_to_edges[node_index];
	if(node_index + 1 == g->current_num_vertices){
		end_index = g->current_num_vertices + g->current_num_edges;
	}
	else {
		end_index = dest_nodes_to_edges[node_index + 1];
	}

	for(i = start_index; i < end_index; ++i){
		edge_index = dest_nodes_to_edges[i];
		edge = &edges[edge_index];

		combine_message(new_message, edge, num_variables);
		has_incoming = 1;

	}
	if(has_incoming == 1){
		for(i = 0; i < num_variables; ++i){
			node->states[i] = new_message[i];
		}
	}
	sum = 0.0;
	for(i = 0; i < num_variables; ++i){
		sum += node->states[i];
	}
	if(sum <= 0.0){
		sum = 1.0;
	}

	for(i = 0; i < num_variables; ++i){
		node->states[i] = node->states[i] / sum;
	}
}

void marginalize(Graph_t g){
	int i, num_nodes;
	Edge_t edges;

	num_nodes = g->current_num_vertices;
	edges = g->edges;

	for(i = 0; i < num_nodes; ++i){
		marginalize_node(g, i, edges);
	}
}

void reset_visited(Graph_t g){
	int i, num_nodes;

	num_nodes = g->current_num_vertices;
	for(i = 0; i < num_nodes; ++i){
		g->visited[i] = 0;
	}
}


void print_node(Graph_t graph, int node_index){
	int i, num_vars, variable_name_index;
	double * states;
	Node_t n;

	n = &graph->nodes[node_index];
	num_vars = n->num_variables;
	states = n->states;

	printf("Node %s [\n", &graph->node_names[node_index * CHAR_BUFFER_SIZE]);
	for(i = 0; i < num_vars; ++i){
		variable_name_index = node_index * CHAR_BUFFER_SIZE * MAX_STATES + i * CHAR_BUFFER_SIZE;
		printf("%s:\t%.6lf\n", &graph->variable_names[variable_name_index], states[i]);
	}
	printf("]\n");
}

void print_edge(Graph_t graph, int edge_index){
	int i, j, dim_x, dim_y;
	Edge_t e;

	e = &graph->edges[edge_index];
	dim_x = e->x_dim;
	dim_y = e->y_dim;

	printf("Edge  %s -> %s [\n", &graph->node_names[e->src_index * CHAR_BUFFER_SIZE], &graph->node_names[e->dest_index * CHAR_BUFFER_SIZE]);
	for(i = 0; i < dim_x; ++i){
		printf("[");
		for(j = 0; j < dim_y; ++j){
			printf("\t%.6lf",  e->joint_probabilities[i][j]);
		}
		printf("\t]\n");
	}
	printf("\n");
}

void print_nodes(Graph_t g){
	int i, num_nodes;

	num_nodes = g->current_num_vertices;

	for(i = 0; i < num_nodes; ++i){
		print_node(g, i);
	}
}

void print_edges(Graph_t g){
	int i, num_edges;

	num_edges = g->current_num_edges;

	for(i = 0; i < num_edges; ++i){
		print_edge(g, i);
	}
}
void print_src_nodes_to_edges(Graph_t g){
	int i, j, start_index, end_index, num_vertices, edge_index;
	int * src_node_to_edges;

	printf("src index -> edge index\n");


	src_node_to_edges = g->src_nodes_to_edges;
	num_vertices = g->total_num_vertices;

	for(i = 0; i < num_vertices; ++i){
		printf("Node -----\n");
		print_node(g, i);
		printf("Edges-------\n");
		start_index = src_node_to_edges[i];
		if(i + 1 == num_vertices){
			end_index = num_vertices + g->current_num_edges;
		}
		else{
			end_index = src_node_to_edges[i+1];
		}
		for(j = start_index; j < end_index; ++j){
			edge_index = src_node_to_edges[j];
			print_edge(g, edge_index);
		}
		printf("---------\n");
	}
}
void print_dest_nodes_to_edges(Graph_t g){
	int i, j, start_index, end_index, num_vertices, edge_index;
	int * dest_node_to_edges;

	printf("dest index -> edge index\n");

	dest_node_to_edges = g->dest_nodes_to_edges;
	num_vertices = g->total_num_vertices;

	for(i = 0; i < num_vertices; ++i){
		printf("Node -----\n");
		print_node(g, i);
		printf("Edges-------\n");
		start_index = dest_node_to_edges[i];
		if(i + 1 == num_vertices){
			end_index = num_vertices + g->current_num_edges;
		}
		else{
			end_index = dest_node_to_edges[i+1];
		}
		for(j = start_index; j < end_index; ++j){
			edge_index = dest_node_to_edges[j];
			print_edge(g, edge_index);
		}
		printf("---------\n");
	}
}

void init_previous_edge(Graph_t graph){
	int i, j, num_vertices, start_index, end_index, edge_index;
	int * src_node_to_edges;
	Edge_t edge, previous;
	Node_t node;

	num_vertices = graph->current_num_vertices;
	src_node_to_edges = graph->src_nodes_to_edges;
	previous = *graph->previous;

	for(i = 0; i < num_vertices; ++i){
		node = &graph->nodes[i];
		start_index = src_node_to_edges[i];
		if(i + 1 >= num_vertices){
			end_index = num_vertices + graph->current_num_edges;
		}
		else
		{
			end_index = src_node_to_edges[i + 1];
		}
		for(j = start_index; j < end_index; ++j){
			edge_index = src_node_to_edges[j];

			edge = &previous[edge_index];

			send_message(edge, node->states);
		}
	}
}

void loopy_propagate_one_iteration(Graph_t graph){
	int i, j, num_variables, num_vertices, start_index, end_index, edge_index;
	int * dest_node_to_edges;
	int * src_node_to_edges;
	Node_t node;
	Edge_t edge, previous, current;
	Edge_t * temp;

	previous = *graph->previous;
	current = *graph->current;

	double message_buffer[MAX_STATES];

	num_vertices = graph->current_num_vertices;
	dest_node_to_edges = graph->dest_nodes_to_edges;
	src_node_to_edges = graph->src_nodes_to_edges;

	for(i = 0; i < num_vertices; ++i){
		node = &graph->nodes[i];
		num_variables = node->num_variables;
		//clear buffer
		for(j = 0; j < num_variables; ++j){
			message_buffer[j] = node->states[j];
		}

		//read incoming messages
		start_index = dest_node_to_edges[i];
		if(i + 1 >= num_vertices){
			end_index = num_vertices + graph->current_num_edges;
		}
		else{
			end_index = dest_node_to_edges[i + 1];
		}

		for(j = start_index; j < end_index; ++j){
			edge_index = dest_node_to_edges[j];
			edge = &previous[edge_index];

			combine_message(message_buffer, edge, num_variables);
		}
/*
		printf("Message at node\n");
		print_node(graph, i);
		printf("[\t");
		for(j = 0; j < num_variables; ++j){
			printf("%.6lf\t", message_buffer[j]);
		}
		printf("\t]\n");*/


		//send message
		start_index = src_node_to_edges[i];
		if(i + 1 >= num_vertices){
			end_index = num_vertices + graph->current_num_edges;
		}
		else {
			end_index = src_node_to_edges[i + 1];
		}
		for(j = start_index; j < end_index; ++j){
			edge_index = src_node_to_edges[j];
			edge = &current[edge_index];
			/*printf("Sending on edge\n");
			print_edge(graph, edge_index);*/
			send_message(edge, message_buffer);
		}

	}

	for(i = 0; i < num_vertices; ++i){
		marginalize_node(graph, i, current);
	}

	//swap previous and current
	temp = graph->previous;
	graph->previous = graph->current;
	graph->current = temp;
}

void loopy_propagate_until(Graph_t graph, double convergence, int max_iterations){
	int i, j, k, num_nodes;
	Edge_t previous_edges, previous, current, current_edges;
	double delta, diff, previous_delta;

	previous_edges = *(graph->previous);
	current_edges = *(graph->current);

	num_nodes = graph->current_num_vertices;

	previous_delta = -1.0;

	for(i = 0; i < max_iterations; ++i){
		printf("Current iteration: %d\n", i+1);
		loopy_propagate_one_iteration(graph);

		delta = 0.0;

		for(j = 0; j < num_nodes; ++j){
			previous = &previous_edges[j];
			current = &current_edges[j];

			for(k = 0; k < previous->x_dim; ++k){
				diff = previous->message[k] - current->message[k];
				if(diff < 0.0){
					diff = diff * -1.0;
				}
				delta += diff;
			}
		}

		printf("Current delta: %.6lf vs Previous delta: %.6lf\n", delta, previous_delta);
		if(delta < convergence || delta == previous_delta){
			break;
		}
		previous_delta = delta;
	}
}