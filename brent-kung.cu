
/*
brent-kung.cu

Jordan Kremer
Dalton Bohning

Usage:
    Flags:
        -DARRAY_SIZE
        -SECTION_SIZE 

    Ex:
        nvcc -DARRAY_SIZE=2000 -DSECTION_SIZE=2048 -o brent-kung brent-kung.cu

    Note:
        Section size should not exceed 2048 
*/


#include <cuda.h>
#include <stdio.h>
#include <math.h> //for ceil()
#include <limits.h>

//#define SECTION_SIZE 100
//#define ARRAY_SIZE 100


#define handleError(CUDA_FUNCTION) {\
    cudaError_t THE_ERROR = (cudaError_t) CUDA_FUNCTION;\
    if (THE_ERROR != cudaSuccess) \
    {\
        printf("%s in %s at line %d\n", cudaGetErrorString(THE_ERROR),__FILE__,__LINE__);\
        exit(EXIT_FAILURE);\
    }\
}



//Credit: https://github.com/aramadia/udacity-cs344/blob/master/Unit2%20Code%20Snippets/gputimer.h
struct GpuTimer
{
      cudaEvent_t start;
      cudaEvent_t stop;
 
      GpuTimer()
      {
            cudaEventCreate(&start);
            cudaEventCreate(&stop);
      }
 
      ~GpuTimer()
      {
            cudaEventDestroy(start);
            cudaEventDestroy(stop);
      }
 
      void Start()
      {
            cudaEventRecord(start, 0);
      }
 
      void Stop()
      {
            cudaEventRecord(stop, 0);
      }
 
      float Elapsed()
      {
            float elapsed;
            cudaEventSynchronize(stop);
            cudaEventElapsedTime(&elapsed, start, stop);
            return elapsed;
      }
};

GpuTimer timer_kernelExecution;
GpuTimer timer_kernelTotal;


//An iterative version of parallel scan addition
__host__
void sequential_scan(float *X, float *Y){
  int acc = X[0];
  Y[0] = acc;

  int i;
  for (i = 1; i < ARRAY_SIZE; ++i) {
    acc += X[i];
    Y[i] = acc;
  }
}

//Runs the iterative version and verifies the results
__host__
bool verify(float *X, float *Y){
  float *Y_ = (float*) malloc(ARRAY_SIZE * sizeof(float));
  sequential_scan(X, Y_);
  for (int i = 0; i < ARRAY_SIZE; ++i){
    if (Y[i] != Y_[i]) {
      printf("Expected %.0f but got %.0f at Y[%d]\n", Y_[i], Y[i], i);
      return false;
    }
  }
  free(Y_);
  return true;
}

//phase 1 calculates the sums for each section (per block)
__global__ 
void Brent_Kung_kernel_phase1(float *X, float *Y, float *S, int size)
{
    __shared__ float XY[SECTION_SIZE];

    int i = 2*blockIdx.x*blockDim.x + threadIdx.x;
    if(i < size)
      XY[threadIdx.x] = X[i];

    if(i + blockDim.x < size)
      XY[threadIdx.x+blockDim.x] = X[i + blockDim.x];

    for (unsigned int stride = 1; stride <= blockDim.x; stride *= 2) {
      __syncthreads();
      int index = (threadIdx.x+1) * 2 * stride - 1;
      if(index < SECTION_SIZE)
        XY[index] += XY[index - stride];
    }
    
    for(int stride = SECTION_SIZE/4; stride > 0; stride /= 2)
    {
      __syncthreads();
      int index = (threadIdx.x+1) * stride * 2 - 1;
      if(index + stride < SECTION_SIZE) 
        XY[index + stride] += XY[index];
    }
    
    __syncthreads();
    if(i < size)
      Y[i] = XY[threadIdx.x];
    
    if(i + blockDim.x < size)
      Y[i + blockDim.x] = XY[threadIdx.x + blockDim.x];

    //Save each section's sum for use in phase2
    if (threadIdx.x == (blockDim.x-1))
      S[blockIdx.x] = XY[SECTION_SIZE - 1];

}

// phase2 is similar to phase1, except it doesn't store each block's sum
// This is meant for when the array fits into a single block
__global__
void Brent_Kung_kernel_phase2(float *X, float *Y, int size)
{
    __shared__ float XY[SECTION_SIZE];

    int i = 2*blockIdx.x*blockDim.x + threadIdx.x;
    if(i < size)
      XY[threadIdx.x] = X[i];

    if(i + blockDim.x < size)
      XY[threadIdx.x+blockDim.x] = X[i + blockDim.x];

    for (unsigned int stride = 1; stride <= blockDim.x; stride *= 2) {
      __syncthreads();
      int index = (threadIdx.x+1) * 2 * stride - 1;
      if(index < SECTION_SIZE)
        XY[index] += XY[index - stride];
    }

    for(int stride = SECTION_SIZE/4; stride > 0; stride /= 2)
    {
      __syncthreads();
      int index = (threadIdx.x+1) * stride * 2 - 1;
      if(index + stride < SECTION_SIZE)
        XY[index + stride] += XY[index];
    }

    __syncthreads();
    if(i < size)
      Y[i] = XY[threadIdx.x];

    if(i + blockDim.x < size)
      Y[i + blockDim.x] = XY[threadIdx.x + blockDim.x];
}

//phase3 adds the phase 2 values to each block
__global__
void Brent_Kung_kernel_phase3(float *Y, float *S, int size)
{
  int i = 2*(blockIdx.x+1)*(blockDim.x) + threadIdx.x;

  //TODO Shared memory for S[]?
  if(i < size)
    Y[i] += S[blockIdx.x];

  if(i + blockDim.x < size)
    Y[i + blockDim.x] += S[blockIdx.x];
}


void inclusive_scan(float *host_X, float *host_Y)
{
    float *X, *Y, *S, *SS;
    int mallocSize = ARRAY_SIZE * sizeof(float);
   
    //Each block calculates a section of the input
    int numBlocks_phase1 = ceil((double)ARRAY_SIZE/SECTION_SIZE);
    int numBlocks_phase2 = ceil((double)numBlocks_phase1/SECTION_SIZE);
    int numBlocks_phase3 = numBlocks_phase1 - 1;

    int numBlocks_phase1s = ceil((double)numBlocks_phase1/SECTION_SIZE);


    bool firstHierarchy = (numBlocks_phase1 > 1);
    bool secondHierarchy = (numBlocks_phase2 > 1);
    

    timer_kernelTotal.Start();

    handleError(cudaMalloc((void **)&X, mallocSize));
    handleError(cudaMalloc((void **)&Y, mallocSize));
    
    if (firstHierarchy)
      handleError(cudaMalloc((void **)&S, numBlocks_phase1*sizeof(float)));
    if (secondHierarchy)
      handleError(cudaMalloc((void **)&SS, numBlocks_phase1s*sizeof(float)));
    


    handleError(cudaMemcpy(X, host_X, mallocSize, cudaMemcpyHostToDevice));
   
    timer_kernelExecution.Start();

    if (!firstHierarchy) {
      // The array fits into a single block. Just do a simple scan
      Brent_Kung_kernel_phase2<<<numBlocks_phase1, SECTION_SIZE/2>>>(X, Y, ARRAY_SIZE);
    }
    else {
      // The array doesn't fit into a single block, so we need to break it down
      Brent_Kung_kernel_phase1<<<numBlocks_phase1, SECTION_SIZE/2>>>(X, Y, S, ARRAY_SIZE);
      
      if (secondHierarchy) {
        // The partial sums for the blocks don't fit into a block, so we must further break it down
        Brent_Kung_kernel_phase1<<<numBlocks_phase1s, SECTION_SIZE/2>>>(S, S, SS, numBlocks_phase1);
        Brent_Kung_kernel_phase2<<<1, SECTION_SIZE/2>>>(SS, SS, numBlocks_phase1s);
        Brent_Kung_kernel_phase3<<<numBlocks_phase1s-1, SECTION_SIZE/2>>>(S, SS, numBlocks_phase1);
      }
      else {
        // The partial sums fit into a single block, so do a simple scan on the partial sums
        Brent_Kung_kernel_phase2<<<1, SECTION_SIZE/2>>>(S, S, numBlocks_phase1);
      }      

      // Add the partial sums back to the blocks for the input array
      Brent_Kung_kernel_phase3<<<numBlocks_phase3, SECTION_SIZE/2>>>(Y, S, ARRAY_SIZE);
    }
    timer_kernelExecution.Stop();

    handleError(cudaMemcpy(host_Y, Y, mallocSize, cudaMemcpyDeviceToHost));
    handleError(cudaFree(X));
    handleError(cudaFree(Y));
    if (firstHierarchy)
      handleError(cudaFree(S));
    if (secondHierarchy)
      handleError(cudaFree(SS));

    timer_kernelTotal.Stop();
}

void printArray(float *A){
  for(int i = 0; i < ARRAY_SIZE; ++i) {
    printf("%.0f ", A[i]);
    if((i+1) % 10 == 0){
      printf("\n");
    }
  }
  printf("\n");
}

int main(void)
{
    float *host_X = (float*) malloc(ARRAY_SIZE * sizeof(float));
    float *host_Y = (float*) malloc(ARRAY_SIZE * sizeof(float));

    for(int i = 0; i < ARRAY_SIZE; ++i)
    {
      host_X[i] = 1;
    }
    


    inclusive_scan(host_X, host_Y);

    //Make sure the results are correct
#if defined(PRINT_RESULTS)
    printArray(host_Y);
#endif
#if defined(VERIFY_RESULTS)
    if (verify(host_X, host_Y))
      printf("ALL CORRECT!\n");
    else
      printf("FAIL!\n");
#endif

    float kernelExec = timer_kernelExecution.Elapsed();
    float kernelTotal = timer_kernelTotal.Elapsed();
    float kernelMem = kernelTotal - kernelExec;

    printf("Kernel Execution (ms): %f\n", kernelExec);
    printf("Kernel Memory (ms):    %f\n", kernelMem);
    printf("Kernel Total (ms):     %f\n", kernelTotal);

    free(host_X);
    free(host_Y);
}
