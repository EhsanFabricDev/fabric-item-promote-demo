# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   }
# META }

# CELL ********************

def read_table(name):
    return spark.read.table(name)

def clean_sales(df):
    return df.dropDuplicates(["order_id"]).filter("amount > 0")
