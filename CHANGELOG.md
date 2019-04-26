# Changelog

## v0.3.0 (2019-04-26)

  * Add `metadata` field to the `Message` struct so clients can append extra information

## v0.2.0 (2019-04-04)

  * `Broadway.Message.put_partition/2` has been renamed to `Broadway.Message.put_batch_key/2`
  * Allow `Broadway.Producer` to `prepare_for_draining/1`
  * Allow pipelines without batchers

## v0.1.0 (2019-02-19)

  * Initial release
