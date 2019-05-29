
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




__global__ 
void Brent_Kung_scan_kernel(float *X, float *Y)
{
    __shared__ float XY[SECTION_SIZE];

    int i = 2*blockIdx.x*blockDim.x + threadIdx.x;
    if(i < ARRAY_SIZE)
    {
        XY[threadIdx.x] = X[i];
    }

    if(i + blockDim.x < ARRAY_SIZE)
    {
        XY[threadIdx.x+blockDim.x] = X[i + blockDim.x];
    }

    for (unsigned int stride = 1; stride <= blockDim.x; stride *= 2) {
        __syncthreads();
        int index = (threadIdx.x+1) * 2 * stride - 1;
        if(index < SECTION_SIZE)
        {
            XY[index] += XY[index - stride];
        }
    }

    for(int stride = SECTION_SIZE/4; stride > 0; stride /= 2)
    {
        __syncthreads();
        int index = (threadIdx.x+1) * stride * 2 - 1;
        if(index + stride < SECTION_SIZE) 
        {
            XY[index + stride] += XY[index];
        }
    }

    __syncthreads();
    if(i < ARRAY_SIZE)
    {
        Y[i] = XY[threadIdx.x];
    }
    
    if(i + blockDim.x < ARRAY_SIZE)
    {
        Y[i + blockDim.x] = XY[threadIdx.x + blockDim.x];
    }

}


void inclusive_scan(float *host_X, float *host_Y)
{
    float *X, *Y;

    handleError(cudaMalloc((void **)&X, ARRAY_SIZE));
    handleError(cudaMalloc((void **)&Y, ARRAY_SIZE));

    handleError(cudaMemcpy(X, host_X, ARRAY_SIZE, cudaMemcpyHostToDevice));
   
    //Book says SECTION_SIZE/2 OK, but not sure about
    //other dimensions and blocks per grid
    dim3 threadsPerBlock(SECTION_SIZE/2, 1, 1);
    dim3 blocksPerGrid(100,1,1);

    GpuTimer timer;
    timer.Start();
    Brent_Kung_scan_kernel<<<blocksPerGrid, threadsPerBlock>>>(X, Y);
    timer.Stop();

    handleError(cudaMemcpy(host_Y, Y, ARRAY_SIZE, cudaMemcpyDeviceToHost));
    handleError(cudaFree(X));
    handleError(cudaFree(Y));

}


int main(void)
{
    float *host_X = (float*)malloc(ARRAY_SIZE);
    float *host_Y = (float*)malloc(ARRAY_SIZE);

    for(int i = 0; i < ARRAY_SIZE; ++i)
    {
        host_X[i] = i + i %4; //change
    }

    inclusive_scan(host_X, host_Y);

    for(int i = 0; i < ARRAY_SIZE; ++i)
    {
        printf("%f", host_Y[i]);
        if(i % 10 == 0){
            printf("\n");
        }
    }
}