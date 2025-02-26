 
#include <math.h>
#include <stdio.h>
// #include <stdlib.h>
// #include <omp.h>
//#include "timer.h" // Include the timer header
//#include <cuda_runtime.h>
// #include "matric.h" // Include your custom matric.h header
// #include <stdio.h>
// #include <assert.h>


#define SOFTENING 1e-9f

typedef struct {
    float x, y, z, vx, vy, vz;
} Body;

// Macro definitions
//#define THROUGHPUT(operations, seconds) ((operations) / (seconds) / 1e9) // GOPS
//#define RATIO_TO_PEAK_BANDWIDTH(actual_bandwidth, peak_bandwidth) ((actual_bandwidth) / (peak_bandwidth))

void randomizeBodies(float *data, int n) {
    for (int i = 0; i < n; i++) {
        data[i] = 2.0f * (rand() / (float)RAND_MAX) - 1.0f;
    }
}

__global__ void bodyForce(Body *p, float dt, int n, float *Fx, float *Fy, float *Fz) {


    // for (int i = 0; i < n; i++) {
         int i = threadIdx.x + blockIdx.x * blockDim.x;
         if (i<n){
            Fx[i] = 0.0f;
            Fy[i] = 0.0f;
            Fz[i] = 0.0f;

            for (int j = 0; j < n; j++) {
                if (i != j) {
                    float dx = p[j].x - p[i].x;
                    float dy = p[j].y - p[i].y;
                    float dz = p[j].z - p[i].z;
                    float distSqr = dx * dx + dy * dy + dz * dz + SOFTENING;
                    float invDist = 1.0f / sqrtf(distSqr);
                    float invDist3 = invDist * invDist * invDist;

                    Fx[i] += dx * invDist3;
                    Fy[i] += dy * invDist3;
                    Fz[i] += dz * invDist3;
                    //printf("stampa f: %d\n",Fx[i]);
                }
            }

            p[i].vx += dt * Fx[i];
            p[i].vy += dt * Fy[i];
            p[i].vz += dt * Fz[i];
    // }
         }
}

void saveForcesToFile(const char *filename, int nBodies, Body *p, float *Fx, float *Fy, float *Fz) {
    FILE *file = fopen(filename, "w");
    if (!file) {
        fprintf(stderr, "Unable to open file %s for writing.\n", filename);
        return;
    }
    for (int i = 0; i < nBodies; i++) {
        fprintf(file, "Body %d: x = %.3f, y = %.3f, z = %.3f, Fx = %.3f, Fy = %.3f, Fz = %.3f\n",
                i, p[i].x, p[i].y, p[i].z, Fx[i], Fy[i], Fz[i]);
    }
    fclose(file);
}

__global__ void integration(int n, Body* p_d, float dt){
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    if (i<n){
        p_d[i].x += p_d[i].vx * dt;
        p_d[i].y += p_d[i].vy * dt;
        p_d[i].z += p_d[i].vz * dt;
    }
}

int main(int argc, char **argv) {

    int nBodies = 30000;
    if (argc > 1) nBodies = atoi(argv[1]);

    const float dt = 0.01f; // time step
    const int nIters = 500;  // simulation iterations

    int bytes = nBodies * sizeof(Body);
    Body *p_h ; //= (Body *)malloc(bytes);
    Body *p_d ; //= (Body *)malloc(bytes);



    cudaMallocHost(&p_h,bytes);
    cudaMalloc(&p_d, bytes);

    if (p_h == NULL || p_h == NULL) {
        fprintf(stderr, "Unable to allocate memory for bodies.\n");
        return 1;
    }

    float *buf = (float *)malloc(6 * nBodies * sizeof(float));
    if (buf == NULL) {
        fprintf(stderr, "Unable to allocate memory for buffer.\n");
        cudaFree(p_h);
        return 1;
    }

    size_t threads_per_blocks = 256;
    size_t number_of_blocks = (nBodies + threads_per_blocks - 1) / threads_per_blocks;

    randomizeBodies(buf, 6 * nBodies); // Init pos / vel data
    for (int i = 0; i < nBodies; i++) {
        p_h[i].x = buf[6 * i];
        p_h[i].y = buf[6 * i + 1];
        p_h[i].z = buf[6 * i + 2];
        p_h[i].vx = buf[6 * i + 3];
        p_h[i].vy = buf[6 * i + 4];
        p_h[i].vz = buf[6 * i + 5];
    }

    free(buf);

    // float *Fx = (float *)malloc(nBodies * sizeof(float));
    // float *Fy = (float *)malloc(nBodies * sizeof(float));
    // float *Fz = (float *)malloc(nBodies * sizeof(float));
    float *Fx_h ;     float *Fx_d ;
    float *Fy_h ;     float *Fy_d ;
    float *Fz_h ;     float *Fz_d ;

    cudaMallocHost(&Fx_h,nBodies * sizeof(float));   cudaMallocHost(&Fy_h,nBodies * sizeof(float));       cudaMallocHost(&Fz_h,nBodies * sizeof(float));
    cudaMalloc(&Fx_d, nBodies * sizeof(float));      cudaMalloc(&Fy_d, nBodies * sizeof(float));          cudaMalloc(&Fz_d, nBodies * sizeof(float));

    if (Fx_h == NULL || Fy_h == NULL || Fz_h == NULL) {
        fprintf(stderr, "Unable to allocate memory for force arrays.\n");
        cudaFreeHost(p_h);
        if (Fx_h) cudaFreeHost(Fx_h);
        if (Fy_h) cudaFreeHost(Fy_h);
        if (Fz_h) cudaFreeHost(Fz_h);
        return 1;
    }

    float totalTime = 0.0;
    cudaMemcpy(p_d,p_h,bytes,cudaMemcpyHostToDevice);

    cudaEvent_t start,stop;
    float time;


    for (int iter = 1; iter <= nIters; iter++) {
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);

        bodyForce<<<number_of_blocks, threads_per_blocks>>>(p_d, dt, nBodies, Fx_d, Fy_d, Fz_d); // compute interbody forces
        cudaDeviceSynchronize();

        integration<<<number_of_blocks, threads_per_blocks>>>(nBodies,p_d,dt);
        cudaDeviceSynchronize();

        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        if (iter > 1) { // First iter is warm up
            cudaEventElapsedTime(&time,start,stop);
            totalTime += time/1000;
        }
        //printf("Iteration %d: %.3f seconds\n", iter, time);
        if (iter==nIters-1) printf("Final Iteration %d: %.3f seconds\n", totalTime);
    }

    cudaMemcpy(p_h,p_d,bytes,cudaMemcpyDeviceToHost);
    cudaMemcpy(Fx_h,Fx_d,nBodies * sizeof(float),cudaMemcpyDeviceToHost);
    cudaMemcpy(Fy_h,Fy_d,nBodies * sizeof(float),cudaMemcpyDeviceToHost);
    cudaMemcpy(Fz_h,Fz_d,nBodies * sizeof(float),cudaMemcpyDeviceToHost);
    saveForcesToFile("forces.txt", nBodies, p_h, Fx_h, Fy_h, Fz_h);

    double avgTime = totalTime / (double)(nIters - 1);
    double rate = (double)nBodies / avgTime;

    printf("Average rate for iterations 2 through %d: %.3f steps per second.\n",
           nIters, rate);
    printf("%d Bodies: average %0.3f Billion Interactions / second\n", nBodies, 1e-9 * nBodies * nBodies / avgTime);

    cudaFreeHost(p_h);
    cudaFree(p_d);

    cudaFreeHost(Fx_h);
    cudaFreeHost(Fy_h);
    cudaFreeHost(Fz_h);

    cudaFree(Fx_d);
    cudaFree(Fy_d);
    cudaFree(Fz_d);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return 0;
}

