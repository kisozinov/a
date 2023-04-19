FROM cr.msk.sbercloud.ru/aicloud-jupyter/jupyter-cuda11.1-pt1.9.1-gpu-a100:0.0.82-1

ARG PYTHON_VERSION=3.8.13
ARG HADOOP_VERSION=3.2.3
ARG SPARK_VERSION=3.2.1
ARG NUMPY_VERSION=1.22.3
ARG SCIPY_VERSION=1.8.1
ARG TORCH_VERSION=1.10.2

USER root

# Fix error caused by some CUDA packages
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys A4B469963BF863CC

RUN apt-get update -y

# Build tools needed for Numpy build
RUN apt-get install \
    build-essential \
    gfortran \
    -y

# JDK is needed for Spark
RUN apt-get install openjdk-11-jdk -y

# Install Hadoop
RUN curl -L https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz > hadoop-${HADOOP_VERSION}.tar.gz
RUN tar xvf hadoop-${HADOOP_VERSION}.tar.gz && \
    mv hadoop-${HADOOP_VERSION} /opt && \
    rm -rf hadoop-${HADOOP_VERSION}.tar.gz

# Install Spark
RUN curl -L https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-without-hadoop.tgz > spark-${SPARK_VERSION}.tar.gz
RUN tar xvf spark-${SPARK_VERSION}.tar.gz && \
    mv spark-${SPARK_VERSION}-bin-without-hadoop /opt/spark-${SPARK_VERSION} && \
    rm -rf spark-${SPARK_VERSION}.tar.gz

# Setup env variables to use Spark
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV HADOOP_HOME=/opt/hadoop-${HADOOP_VERSION}
ENV SPARK_HOME=/opt/spark-${SPARK_VERSION}
ENV LD_LIBRARY_PATH=/opt/hadoop-${HADOOP_VERSION}/lib/native:${LD_LIBRARY_PATH}

ENV SPARK_DIST_CLASSPATH=\
"/opt/hadoop-${HADOOP_VERSION}/etc/hadoop:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/common/lib/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/common/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/hdfs:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/hdfs/lib/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/hdfs/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/mapreduce/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/yarn:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/yarn/lib/*:\
/opt/hadoop-${HADOOP_VERSION}/share/hadoop/yarn/*"

# pySpark is already part of downloaded binaries, so we set
# PYTHONPATH to its location instead downloading with pip
ENV PYTHONPATH=\
"${SPARK_HOME}/python/lib/pyspark.zip:\
${SPARK_HOME}/python/lib/py4j-0.10.9.3-src.zip:\
${PYTHONPATH}"

# Add extra packages to Spark:
# We explicitly download JAR packages with ivy and copy to default directory
# to avoid downloading packages at Airflow runtime with `spark-submit --packages ...`
COPY spark-ivy-dependencies.xml spark-packages/ivy.xml
RUN cd spark-packages && \
    java -jar ${SPARK_HOME}/jars/ivy-2.5.0.jar -cachepath jars.txt && \
    cat jars.txt | tr -d "\n" | xargs -d ":" -I{} cp {} ${SPARK_HOME}/jars && \
    rm -rf spark-packages && \
    rm -rf ~/.ivy2/cache

# Make sure Spark shell can be initialized
RUN ${SPARK_HOME}/bin/spark-shell <<< ":quit"

USER jovyan

RUN rm -rf /home/user/conda
RUN wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-py38_4.12.0-Linux-x86_64.sh -O ~/miniconda.sh && \
    /bin/bash ~/miniconda.sh -b -p /home/user/conda && \
    rm ~/miniconda.sh

RUN conda install conda-build mamba -c conda-forge

# Update pip
RUN pip install --upgrade pip

COPY requirements-base.txt .
RUN pip install -r requirements-base.txt

# Install last version of MKL
RUN pip install mkl-devel==2022.2.0

# Fix symlink to mkl_rt to let numpy ans scipy find MKL
RUN cd /home/user/conda/lib && \
    ln libmkl_rt.so.2 libmkl_rt.so

# Create site.cfg to build numpy and scipy with MKL
RUN echo -e "\
[mkl]\n\
include_dirs = /home/user/conda/include\n\
library_dirs = /home/user/conda/lib\n\
mkl_libs = mkl_rt\n\
lapack_libs = mkl_rt\n\
" > ./numpy.cfg

# Install NumPy
RUN curl -L https://github.com/numpy/numpy/releases/download/v${NUMPY_VERSION}/numpy-${NUMPY_VERSION}.tar.gz > numpy-${NUMPY_VERSION}.tar.gz && \
    tar xvf numpy-${NUMPY_VERSION}.tar.gz && \
    cp numpy.cfg ./numpy-${NUMPY_VERSION}/site.cfg
RUN export NPY_NUM_BUILD_JOBS=16 && \
    export NPY_BLAS_ORDER=MKL,ATLAS,blis,openblas && \
    export NPY_LAPACK_ORDER=MKL,ATLAS,openblas && \
    cd ./numpy-${NUMPY_VERSION} && \
    pip install --verbose .
RUN rm -rf ./numpy-${NUMPY_VERSION} numpy-${NUMPY_VERSION}.tar.gz

# Install SciPy
RUN curl -L https://github.com/scipy/scipy/releases/download/v${SCIPY_VERSION}/scipy-${SCIPY_VERSION}.tar.gz > scipy-${SCIPY_VERSION}.tar.gz && \
    tar xvf scipy-${SCIPY_VERSION}.tar.gz && \
    cp numpy.cfg ./scipy-${SCIPY_VERSION}/site.cfg
RUN export NPY_NUM_BUILD_JOBS=16 && \
    export NPY_BLAS_ORDER=MKL,ATLAS,blis,openblas && \
    export NPY_LAPACK_ORDER=MKL,ATLAS,openblas && \
    cd ./scipy-${SCIPY_VERSION} && \
    pip install --verbose .
RUN rm -rf ./scipy-${SCIPY_VERSION} scipy-${SCIPY_VERSION}.tar.gz

# Cleanup
RUN rm -rf site.cfg

# Add path to MKL to environment
ENV LD_LIBRARY_PATH=/home/user/conda/lib:$LD_LIBRARY_PATH

# Install PyTorch outside of requirements.txt to take advantage of Docker layers
RUN pip install torch==${TORCH_VERSION}+cu111 --extra-index-url https://download.pytorch.org/whl/cu111

COPY requirements-jupyter.txt .
RUN pip install -r requirements-jupyter.txt

COPY requirements-essential.txt .
RUN pip install -r requirements-essential.txt

COPY requirements-boosting.txt .
RUN pip install -r requirements-boosting.txt

COPY requirements-recsys.txt .
RUN pip install -r requirements-recsys.txt

# Replace default MLSpace script to ours
ENV PYTHON_LIB_PATH=/home/user/conda/lib/python3.8
COPY mlspace-start-script.sh /home/user/script.sh

RUN conda create -n research-base
