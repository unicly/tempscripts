# Filter Client A's trail to data lake events only

Yes, it’s possible. The filtering is done on Client A’s trail, so it only writes data-lake events in the first
place. Their replication rule can then stay as it is, because everything in that bucket is already relevant.

## Change Client A’s trail to log only the data lake bucket

In account A, they go to CloudTrail, open Trails, select the trail, and edit Data events. They set the log
selector template to Custom with these conditions:

```json
[
  {
    "Name": "Data lake access only",
    "FieldSelectors": [
      { "Field": "eventCategory",  "Equals": ["Data"] },
      { "Field": "resources.type", "Equals": ["AWS::S3::Object"] },
      { "Field": "resources.ARN",  "StartsWith": ["arn:aws:s3:::<DATA_LAKE_BUCKET>/"] }
    ]
  }
]
```

Two details to get right:

- Management events must be turned off on that trail, otherwise all their account activity keeps flowing to you.
- The trailing `/` after the bucket name matters, so a bucket named `datalake-backup` isn’t matched by `datalake`.

## What to expect after the change

Because of how Access Grants works, Client A’s trail may end up with few or no events for the data lake. Their
users read data with temporary credentials that belong to your location role in account B, so AWS treats those
reads as account B activity and records them on your side.

So when they test:

- **If events appear in A’s filtered trail:** they’re reaching the bucket with their own identity, and this setup
  gives you exactly what you need.
- **If the trail stays empty even though they’re reading data:** the activity is being recorded in your account.
  In that case, the reliable source is a trail in account B on the data lake bucket, filtered on
  `userIdentity.arn` starting with `arn:aws:sts::<B_ACCOUNT_ID>:assumed-role/<CLIENT_A_LOCATION_ROLE_NAME>/`.
  You’d then get only Client A’s data-lake activity, without depending on their setup.

Logs that were already replicated before the change stay in your bucket. A lifecycle rule or a manual cleanup can
remove them.

## Next step

Can you ask Client A to apply the filter, read a few files from the data lake, and tell me whether events show up
in their trail after about 15 minutes? That tells us which of the two cases you’re in.
