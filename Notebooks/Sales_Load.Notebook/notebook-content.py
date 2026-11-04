# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   }
# META }

# CELL ********************

%run nb_utils

# CELL ********************

sales = read_table("raw.sales")
sales.write.mode("overwrite").saveAsTable("curated.sales")
