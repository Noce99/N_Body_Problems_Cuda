 
#include <math.h>
#include <stdio.h>
// #include <stdlib.h>
// #include <omp.h>
// #include "timer.h" // Include the timer header
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

int main(int argc, char **argv) {
    printf("aaaaaaaa");
    int nBodies = 30000;
    if (argc > 1) nBodies = atoi(argv[1]);

    const float dt = 0.01f; // time step
    const int nIters = 10;  // simulation iterations

    int bytes = nBodies * sizeof(Body);
    Body *p_h ; //= (Body *)malloc(bytes);
    Body *p_d ; //= (Body *)malloc(bytes);
    printf("aaaaaaaa");
    cudaMallocHost(&p_h,bytes);
    cudaMalloc(&p_d, bytes);
    printf("aaaaaaaa");
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

    float *Fx = (float *)malloc(nBodies * sizeof(float));
    float *Fy = (float *)malloc(nBodies * sizeof(float));
    float *Fz = (float *)malloc(nBodies * sizeof(float));
    if (Fx == NULL || Fy == NULL || Fz == NULL) {
        fprintf(stderr, "Unable to allocate memory for force arrays.\n");
        cudaFree(p_h);
        if (Fx) free(Fx);
        if (Fy) free(Fy);
        if (Fz) free(Fz);
        return 1;
    }

    double totalTime = 0.0;
    cudaMemcpy(p_d,p_h,bytes,cudaMemcpyHostToDevice);


    for (int iter = 1; iter <= nIters; iter++) {
        StartTimer();


        bodyForce<<<number_of_blocks, threads_per_blocks>>>(p_d, dt, nBodies, Fx, Fy, Fz); // compute interbody forces

        for (int i = 0; i < nBodies; i++) { // integrate position
            p_d[i].x += p_d[i].vx * dt;
            p_d[i].y += p_d[i].vy * dt;
            p_d[i].z += p_d[i].vz * dt;
        }

        const double tElapsed = GetTimer() / 1000.0;
        if (iter > 1) { // First iter is warm up
            totalTime += tElapsed;
        }
        printf("Iteration %d: %.3f seconds\n", iter, tElapsed);
    }
    cudaMemcpy(p_h,p_d,bytes,cudaMemcpyDeviceToHost);
    saveForcesToFile("forces.txt", nBodies, p_h, Fx, Fy, Fz);

    double avgTime = totalTime / (double)(nIters - 1);
    double rate = (double)nBodies / avgTime;

    printf("Average rate for iterations 2 through %d: %.3f steps per second.\n",
           nIters, rate);
    printf("%d Bodies: average %0.3f Billion Interactions / second\n", nBodies, 1e-9 * nBodies * nBodies / avgTime);

    cudaFreeHost(p_h);
    cudaFree(p_d);
    free(Fx);
    free(Fy);
    free(Fz);

    return 0;
}
