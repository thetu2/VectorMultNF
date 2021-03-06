
/**
 * Vector multiplication, element wise C = A * B. Complex multiplication for each element is Not Foiled
 **/
 

#include <stdio.h>

// For the CUDA runtime routines (prefixed with "cuda_")
#include <cuda_runtime.h>

#include "lib/helper_cuda.h"
#include "cuComplex.h"
#include "cuda_fp16.h"



//select variable type: 1=real, 2=complex32, 3=half2, 4=2x half
#define TYPE 1
#define COMPCAP 610  //gtx 9xx is 510, gtx 10xx is 610 (need to input manually since __CUDA_ARCH__ is undef in host code)

#if TYPE==1
    #define VARTYPE float
#elif TYPE==2
    #define VARTYPE cuComplex
#elif TYPE==3
    #define VARTYPE __half2
#else 
    #define VARTYPE cmplx16 
#endif


struct cmplx16 {
    __half x;
    __half y;
};

struct cmplx_half2{
    __half2 x;
};

__device__ inline cmplx_half2 operator*(const cmplx_half2& a, const cmplx_half2& b) {
    #if COMPCAP >= 530
        
        const cmplx_half2 answer = {__hmul2(a.x, b.x)};
    #else
        //do nothing
    #endif
        return answer;
}

__device__ inline cmplx16 operator+(const cmplx16& a, const cmplx16& b) {
    #if COMPCAP >= 530
        const auto x = __hadd(a.x, b.x);
        const auto y = __hadd(a.y, b.y);
    #else
        const auto x = __float2half(__half2float(a.x) + __half2float(b.x));
        const auto y = __float2half(__half2float(a.y) + __half2float(b.y));
    #endif
    const  cmplx16 answer = {x, y};
    return answer;
}

__device__ inline cmplx16 operator*(const cmplx16& a, const cmplx16& b) {
#if COMPCAP >= 530
    const auto x = __hmul(a.x, b.x);
    const auto y = __hmul(a.y, b.y);
#else
    //const auto x = __float2half(__half2float(a.x)*__half2float(b.x)- __half2float(a.y) * __half2float(b.y));
    //const auto y = __float2half(__half2float(a.x) * __half2float(b.y) + __half2float(a.y) * __half2float(b.x));
#endif
    const  cmplx16 answer = { x, y };
    return answer;
}

__host__ __device__ inline cuComplex operator+(const cuComplex& a, const cuComplex& b) {
    const auto x = a.x + b.x;
    const auto y = a.y + b.y;
    const  cuComplex answer = {x, y};
    return answer;
}

__host__ __device__ inline cuComplex operator*(const cuComplex& a, const cuComplex& b) {
    const auto x = a.x*b.x;
    const auto y = a.y*b.y;
    const  cuComplex answer = { x, y };
    return answer;
}



template <typename T>
__global__ void vectorMult(const T *A, const T *B, T *C, int numElements)
{
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < numElements)
    {
        C[i] = A[i] * B[i];
    }
}


/**
 * Host main routine
 */
int
main(void)
{
    const int n_trials = 10000; // Number of montecarlo simulations to perform to get a better sense of the average stats. 
    // Error code to check return values for CUDA calls
    cudaError_t err = cudaSuccess;

    // Print the vector length to be used, and compute its size
    int numElements = 500000;
    size_t size = numElements * sizeof(VARTYPE);
    printf("[Element wise vector multiplication of %d elements]\n", numElements);

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // Allocate the host input vector A
    VARTYPE *h_A = (VARTYPE *)malloc(size);

    // Allocate the host input vector B
    VARTYPE *h_B = (VARTYPE *)malloc(size);

    // Allocate the host output vector C
    VARTYPE *h_C = (VARTYPE *)malloc(size);

    // Verify that allocations succeeded
    if (h_A == NULL || h_B == NULL || h_C == NULL)
    {
        fprintf(stderr, "Failed to allocate host vectors!\n");
        exit(EXIT_FAILURE);
    }
    // Initialize the host input vectors
    #if TYPE==1
    
        for (int i = 0; i < numElements; ++i)
        {
            h_A[i] = rand() / (float)RAND_MAX;
            h_B[i] = rand() / (float)RAND_MAX;
        }
    #elif TYPE==2 || TYPE==4
        for (int i = 0; i < numElements; ++i)
        {
            h_A[i].x = rand() / (float)RAND_MAX;
            h_A[i].y = rand() / (float)RAND_MAX;
            h_B[i].x = rand() / (float)RAND_MAX;
            h_B[i].y = rand() / (float)RAND_MAX;
        }
    #elif TYPE==3
        float2 temp_A_float2;
        float2 temp_B_float2;   
        for (int i = 0; i < numElements; ++i)
        {
            temp_A_float2.x = rand() / (float)RAND_MAX;
            temp_A_float2.y = rand() / (float)RAND_MAX;
            h_A[i] = __float22half2_rn(temp_A_float2);
            temp_B_float2.x = rand() / (float)RAND_MAX;
            temp_B_float2.y = rand() / (float)RAND_MAX;
            h_B[i] = __float22half2_rn(temp_B_float2);

        }
    #endif


    // Allocate the device input vector A
    VARTYPE *d_A = NULL;
    err = cudaMalloc((void **)&d_A, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector A (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Allocate the device input vector B
    VARTYPE *d_B = NULL;
    err = cudaMalloc((void **)&d_B, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector B (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Allocate the device output vector C
    VARTYPE *d_C = NULL;
    err = cudaMalloc((void **)&d_C, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector C (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }


    // Setup CUDA grid.
    int threadsPerBlock = 256;
    int blocksPerGrid = (numElements + threadsPerBlock - 1) / threadsPerBlock;
    printf("CUDA kernel launch with %d blocks of %d threads\n", blocksPerGrid, threadsPerBlock);

    //For total elapsed time.
    float total_time = 0;

    for (int i = 0; i < n_trials; i++) {
        // Copy the host input vectors A and B in host memory to the device input vectors in
        // device memory
        //printf("Copy input data from the host memory to the CUDA device\n");
        //event start was HERE
        cudaEventRecord(start);
        err = cudaMemcpy(d_A, h_A, size, cudaMemcpyHostToDevice);

        if (err != cudaSuccess)
        {
            fprintf(stderr, "Failed to copy vector A from host to device (error code %s)!\n", cudaGetErrorString(err));
            exit(EXIT_FAILURE);
        }
        
        err = cudaMemcpy(d_B, h_B, size, cudaMemcpyHostToDevice);

        if (err != cudaSuccess)
        {
            fprintf(stderr, "Failed to copy vector B from host to device (error code %s)!\n", cudaGetErrorString(err));
            exit(EXIT_FAILURE);
        }
        
        vectorMult<VARTYPE> << <blocksPerGrid, threadsPerBlock >> > (d_A, d_B, d_C, numElements);
         
        err = cudaGetLastError();
        if (err != cudaSuccess)
        {
            fprintf(stderr, "Failed to launch vectorAdd kernel (error code %s)!\n", cudaGetErrorString(err));
            exit(EXIT_FAILURE);
        }

        // Copy the device result vector in device memory to the host result vector
        // in host memory.
        //printf("Copy output data from the CUDA device to the host memory\n");
        err = cudaMemcpy(h_C, d_C, size, cudaMemcpyDeviceToHost);
        //event stop was HERE
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float milliseconds = 0;
        cudaEventElapsedTime(&milliseconds, start, stop);
        total_time = milliseconds + total_time;
    }

    

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to copy vector C from device to host (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Verify that the result vector is correct
    //for (int i = 0; i < numElements; ++i)
    //{
    //    if (fabs(h_A[i] + h_B[i] - h_C[i]) > 1e-5)
    //    {
    //        fprintf(stderr, "Result verification failed at element %d!\n", i);
    //        exit(EXIT_FAILURE);
    //    }
    //}

    int idx1= 6;

    #if TYPE==1
    printf("Variable type : real\n");
        printf("Sample output on index %d: %f*%f=%f\n", idx1, h_A[idx1], h_B[idx1], h_C[idx1]);
    #elif TYPE==2
        printf("Variable type : complex32\n");
        printf("Sample output on index %d: (%f+%fi)*(%f+%fi)=%f+%fi\n", idx1, h_A[idx1].x, h_A[idx1].y, h_B[idx1].x, h_B[idx1].y, h_C[idx1].x, h_C[idx1].y);
    #elif TYPE==3
        float2 sample_val_A=__half22float2(h_A[idx1]);
        float2 sample_val_B=__half22float2(h_B[idx1]);
        float2 sample_val_C= __half22float2(h_C[idx1]);

        printf("Variable type : half2\n");
        printf("Sample output on index %d: (%f+%fi)*(%f+%fi)=%f+%fi\n", idx1, sample_val_A.x, sample_val_A.y, sample_val_B.x, sample_val_B.y,
            sample_val_C.x, sample_val_C.y);
    #else

        printf("Variable type : 2x half\n");
        printf("Sample output on index %d: (%f+%fi)*(%f+%fi)=%f+%fi\n", idx1, __half2float(h_A[idx1].x), __half2float(h_A[idx1].y),
            __half2float(h_B[idx1].x), __half2float(h_B[idx1].y), __half2float(h_C[idx1].x), __half2float(h_C[idx1].y));
    #endif


    printf("Total elapsed time including kernel execution and mem transfers from device to host: %f ms\n", total_time);
    auto average_time = total_time / n_trials;
    printf("Average time per trial: %f ms\n", average_time);

    // Free device global memory
    err = cudaFree(d_A);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector A (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaFree(d_B);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector B (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaFree(d_C);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector C (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Free host memory
    free(h_A);
    free(h_B);
    free(h_C);

    printf("Done\n");
    return 0;
}

