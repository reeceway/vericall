export type ChannelVariant = 'general' | 'esafe';

export const resolveChannelVariant = (value?: string): ChannelVariant =>
	value === 'general' ? 'general' : 'esafe';

export const getChannelCopy = (channelVariant: ChannelVariant) =>
	channelVariant === 'general'
		? {
				scene9Footer:
					'Talk to your MSP to add Vicall to your security package. Deployment takes under an hour per company, and your team does not touch anything.',
				closeHeadline: 'Available now through your MSP',
				closeSubline: 'Powered by Vicall',
		  }
		: {
				scene9Footer:
					'Talk to your E-Safe rep to add Vicall to your security package. Deployment takes under an hour per company, and your team does not touch anything.',
				closeHeadline: 'Available now through E-Safe',
				closeSubline: 'Powered by Vicall · Exclusive channel partner: E-Safe Partners',
		  };
