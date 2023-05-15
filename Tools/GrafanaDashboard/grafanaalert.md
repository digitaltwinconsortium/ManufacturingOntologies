# Grafana alert setup

In this example we will create a low OEE alert for one of the production lines. First login to your Grafana service and select in the menu for Alert rules.

![Navigate](navigatetoalerts.png)

Then click on 'Create Rule' on the right.

![Create rule](createrule.png)

Then give your alert a name and select 'Azure Data Explorer' as data source. Click on query on the left

![Alert query](alertquery.png)

Put in the following in the query field and try to run your query. In this example we use the 'Seattle' production line. 

```
let oee = CalculateOEEForStation("assembly", "seattle", 6, 6);
print round(oee * 100, 2)
```
and select 'table' as output. 

Scroll down to the next section. In this example your will configure the alert threshold. In this example we will use below '10' as threshold, but in production environment this will be higher.

![Threshold Alert](threshold%20alert.png)

Select the folder where you want to save your alerts and configure the 'Alert Evaluation behavior' - select there every 2 minutes. 

Hit the 'Save and exit' button on the top. 

Now you will see in the overview of your alerts that an alert is triggered when your OEE is below '10'. 

![Alert overview](alertoverview.png)

Now you can integrate this with for example 'Microsoft Dynamics Field Services' or other own services. 
