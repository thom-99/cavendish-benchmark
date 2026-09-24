from pathlib import Path
import os
import sys
import numpy
import pysam
from setuptools import Extension, setup
from Cython.Build import cythonize
root = Path(__file__).resolve().parent
source = root / 'dysgu-1.9.0'
os.chdir(source)
setup(name='dysgu-cluster-check', ext_modules=cythonize([
    Extension('dysgu.cluster', ['dysgu/cluster.pyx'], language='c++',
              include_dirs=[str(source), str(source/'dysgu'), str(source/'dysgu/include'), numpy.get_include(), *pysam.get_include(), sys.prefix+'/include'],
              library_dirs=[sys.prefix+'/lib'], libraries=['hts'],
              runtime_library_dirs=[sys.prefix+'/lib'],
              define_macros=[('NPY_NO_DEPRECATED_API', 'NPY_1_7_API_VERSION')],
              extra_compile_args=['-std=c++17', '-O2'])
], include_path=[str(source), str(source/'dysgu')], compiler_directives={'language_level':3}))
