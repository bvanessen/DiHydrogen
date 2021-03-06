#include "p2p/p2p.hpp"
#include "p2p/util.hpp"
#include "p2p/util_cuda.hpp"
#include "p2p/logging.hpp"
#include "test_util.hpp"

#include <iostream>
#include <cassert>
#include <cstdlib>
#include <sstream>
#include <thread>
#include <chrono>
#include "cuda_profiler_api.h"

__global__ void kernel(long long int sleep_cycles) {
  auto start = clock64();
  while (true) {
    auto now = clock64();
    if (now - start > sleep_cycles) {
      break;
    }
  }
  return;
}

int test_bandwidth(int pid, p2p::P2P &p2p,
                   size_t min_size, size_t max_size,
                   int iter) {
  void *buf1, *buf2;
  P2P_CHECK_CUDA_ALWAYS(cudaMalloc(&buf1, max_size));
  cudaStream_t st;
  P2P_CHECK_CUDA_ALWAYS(cudaStreamCreate(&st));
  int peer = (pid % 2) == 0 ? pid + 1 : pid - 1;
  p2p::P2P::connection_type conn;
  p2p.get_connections(&peer, &conn, 1);
  conn->exchange_addr(buf1, &buf2);
  cudaEvent_t ev1, ev2;
  P2P_CHECK_CUDA_ALWAYS(cudaEventCreate(&ev1));
  P2P_CHECK_CUDA_ALWAYS(cudaEventCreate(&ev2));
  int skip = 5;
  for (size_t size = min_size; size <= max_size;
       size *= 2) {
    MPI_Barrier(MPI_COMM_WORLD);
    p2p::logging::MPIPrintStreamInfo() << "Testing " << size << "\n";
    P2P_CHECK_CUDA_ALWAYS(cudaStreamSynchronize(st));

    if (pid == 0) {
      kernel<<<1, 1, 0, st>>>((long long int)(1) * 1000 * 1000 * 1000
                              * 1);
    }

    for (int i = 0; i < iter + skip; ++i) {
      p2p::logging::MPIPrintStreamInfo() << "i: " << i << "\n";      
      if (i == skip) {
        P2P_CHECK_CUDA(cudaEventRecord(ev1, st));
      }
      if (pid == 0) {
        conn->send(buf1, buf2, size, st);
        conn->recv(buf2, buf1, size, st);  
      } else {
        conn->recv(buf2, buf1, size, st);
        conn->send(buf1, buf2, size, st);
      }
      P2P_CHECK_CUDA_ALWAYS(cudaStreamSynchronize(st));      
    }
    P2P_CHECK_CUDA(cudaEventRecord(ev2, st));
    P2P_CHECK_CUDA_ALWAYS(cudaStreamSynchronize(st));

    float elaplsed;
    P2P_CHECK_CUDA(cudaEventElapsedTime(&elaplsed, ev1, ev2));
    elaplsed /= 2;
    if (pid == 0) {
      std::stringstream ss;
      ss << size << " "
         << elaplsed / iter << "\n";
      std::cout << ss.str();
    }
  }
  MPI_Barrier(MPI_COMM_WORLD);
  p2p::logging::MPIPrintStreamInfo() << __FUNCTION__ << " done\n";  
  p2p.disconnect_all();
  return 0;
}


int main(int argc, char *argv[]) {
  size_t min_size = 1;
  size_t max_size = 1 << 24;
  int iter = 10;

  assert(argc <= 4);
  
  if (argc == 2) {
    min_size = std::atol(argv[1]);
    max_size = min_size;
  }
  if (argc >= 3) {
    min_size = std::atol(argv[1]);    
    max_size = std::atol(argv[2]);
  }
  if (argc >= 4) {
    iter = std::atoi(argv[3]);
  }
  
  int local_rank = get_local_rank();
  std::cerr << "local rank: " << local_rank << "\n";
  
  P2P_CHECK_CUDA_ALWAYS(cudaSetDevice(local_rank));
  std::cerr << "cuda devise set: " << local_rank << "\n";

  int mpi_thread_level;
  MPI_Init_thread(&argc, &argv, MPI_THREAD_MULTIPLE, &mpi_thread_level);
  switch (mpi_thread_level) {
    case MPI_THREAD_MULTIPLE:
      std::cout << "Supported thread level: MPI_THREAD_MULTIPLE\n";
      break;
    case MPI_THREAD_SINGLE:
      std::cout << "Supported thread level: MPI_THREAD_SINGLE\n";
      break;
    case MPI_THREAD_SERIALIZED:
      std::cout << "Supported thread level: MPI_THREAD_SERIALIZED\n";
      break;
    case MPI_THREAD_FUNNELED:
      std::cout << "Supported thread level: MPI_THREAD_FUNNELED\n";
      break;
  }
  int pid;
  int np;
  MPI_Comm_rank(MPI_COMM_WORLD, &pid);
  MPI_Comm_size(MPI_COMM_WORLD, &np);
  P2P_ASSERT_ALWAYS(np == 2);

  
  p2p::P2P p2p(MPI_COMM_WORLD);

  //p2p.enable_nvtx();
  
  TEST_RUN(test_bandwidth(pid, p2p, min_size, max_size, iter));
  
  p2p.disconnect_all();

  MPI_Finalize();
  return 0;
}
