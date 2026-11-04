# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   }
# META }

# CELL ********************

%run nb_report_helpers

# CELL ********************

monthly_totals(spark.read.table("curated.sales")).write.mode("overwrite").saveAsTable("gold.sales_monthly")
