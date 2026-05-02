import React from 'react';
import {Composition} from 'remotion';
import {resolveChannelVariant} from './channelCopy';
import {ViCallDemo} from './ViCallDemo';
import {frameConstants} from './theme';
import {totalSceneDuration} from './timing';

export const Root: React.FC = () => {
	const channelVariant = resolveChannelVariant(process.env.VICALL_CHANNEL_VARIANT);

	return (
		<>
			<Composition
				id="ViCallDemo"
				component={ViCallDemo}
				defaultProps={{channelVariant}}
				durationInFrames={totalSceneDuration}
				fps={frameConstants.fps}
				width={frameConstants.width}
				height={frameConstants.height}
			/>
		</>
	);
};
