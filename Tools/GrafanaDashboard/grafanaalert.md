# Grafana Alerts Setup

In this example, we will create a low OEE alert for one of the production lines. First, login to your Grafana service and select Alert rules in the menu.

![Navigate](navigatetoalerts.png)

Then click on 'Create Rule' on the right.

![Create rule](createrule.png)

Then give your alert a name and select 'Azure Data Explorer' as data source. Click on query on the left

![Alert query](alertquery.png)

In the query field, enter the following. In this example, we will use the 'Seattle' production line. 

```
let oee = CalculateOEEForStation("assembly", "seattle", 6, 6);
print round(oee * 100, 2)
```
and select 'table' as output. 

Scroll down to the next section. Here, you will configure the alert threshold. In this example, we will use 'below 10' as the threshold, but in production environments, this will be higher.

![Threshold Alert](threshold%20alert.png)

Select the folder where you want to save your alerts and configure the 'Alert Evaluation behavior' - here, select 'every 2 minutes'.

Hit the 'Save and exit' button on the top. 

In the overview of your alerts, you can now see an alert being triggered when your OEE is below '10'.

![Alert overview](alertoverview.png)

You can integrate this with, for example, Microsoft Dynamics Field Services.
