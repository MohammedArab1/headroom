# Allow both `python3 -m unittest discover -s tests` and `python3 -m unittest tests.test_data`.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
